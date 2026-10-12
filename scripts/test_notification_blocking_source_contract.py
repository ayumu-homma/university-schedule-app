"""Static source-contract checks for block-aware group-comment notifications.

This script does not execute PostgreSQL or prove runtime behavior. It protects
the wiring between the comment trigger, symmetric block predicate, and the
notification inbox/outbox filters.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = (
    ROOT / "supabase/migrations/20260923063000_notification_inbox_outbox.sql"
)
SQL = MIGRATION.read_text(encoding="utf-8")


def _function_body(name: str) -> str:
    pattern = re.compile(
        rf"create\s+or\s+replace\s+function\s+private\.{re.escape(name)}\b"
        r".*?\bas\s+\$\$(.*?)\$\$\s*;",
        re.IGNORECASE | re.DOTALL,
    )
    match = pattern.search(SQL)
    if match is None:
        raise AssertionError(f"private.{name} function body not found")
    return re.sub(r"\s+", " ", match.group(1)).lower()


class GroupCommentNotificationBlockContractTest(unittest.TestCase):
    def test_recipient_filter_checks_both_block_directions(self) -> None:
        body = _function_body("notification_recipient_allowed")
        symmetric_guard = (
            "not exists (select 1 from public.blocks b where "
            "(b.blocker_user_id=p_recipient and b.blocked_user_id=p_actor) or "
            "(b.blocker_user_id=p_actor and b.blocked_user_id=p_recipient))"
        )
        self.assertIn(symmetric_guard, body)

    def test_enqueue_filters_recipients_before_inbox_or_outbox_insert(self) -> None:
        body = _function_body("enqueue_group_notification")
        predicate = "private.notification_recipient_allowed(p_group_id,m.user_id,p_actor)"
        self.assertIn(predicate, body)
        self.assertIn("select m.user_id from public.group_members m", body)
        predicate_offset = body.index(predicate)
        inbox_insert_offset = body.index("insert into private.notification_inbox")
        outbox_insert_offset = body.index("insert into private.notification_outbox")
        self.assertLess(predicate_offset, inbox_insert_offset)
        self.assertLess(inbox_insert_offset, outbox_insert_offset)

    def test_comment_insert_trigger_uses_author_as_filtered_actor(self) -> None:
        body = _function_body("notification_group_comment_outbox")
        self.assertIn(
            "perform private.enqueue_group_notification('group_comment',gid,new.event_id,null,new.author_user_id)",
            body,
        )
        trigger = re.sub(r"\s+", " ", SQL).lower()
        self.assertRegex(
            trigger,
            r"create trigger notification_group_comment_created "
            r"after insert on public\.event_comments for each row "
            r"execute function private\.notification_group_comment_outbox\(\)",
        )

    def test_inbox_and_delivery_revalidate_block_eligibility(self) -> None:
        inbox = _function_body("notification_inbox_allowed")
        delivery = _function_body("notification_delivery_allowed")
        self.assertIn("private.notification_recipient_allowed(p_group_id,p_recipient,p_actor)", inbox)
        self.assertIn(
            "not exists(select 1 from public.blocks b where "
            "(b.blocker_user_id=p_recipient and b.blocked_user_id=p_actor) or "
            "(b.blocker_user_id=p_actor and b.blocked_user_id=p_recipient))",
            inbox,
        )
        self.assertIn(
            "selectprivate.notification_inbox_allowed(p_type,p_group_id,p_event_id,p_invitation_id,p_recipient,p_actor)",
            re.sub(r"\s+", "", delivery),
        )


if __name__ == "__main__":
    unittest.main()
