"""Static source-contract checks for blocked friend schedule projection.

These checks guard the SQL definition and migration wiring. They do not run
PostgreSQL or replace the isolated P30 runtime acceptance.
"""

from collections import Counter
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "supabase/migrations"
PHASE8 = MIGRATIONS / "20260920081943_phase8_friend_sharing.sql"
PHASE15 = MIGRATIONS / "20260922150000_phase15_moderation.sql"
SAFETY = MIGRATIONS / "20260923064500_safety_moderation_enforcement.sql"
PHASE6 = MIGRATIONS / "20260924020233_friend_assignment_kind_visibility.sql"
VISIBILITY_PRECEDENCE = MIGRATIONS / "20260928130000_p115_friend_default_visibility_precedence.sql"
SAFETY_RESTORATION = MIGRATIONS / "20260928140000_p116_restore_share01_safety_wrapper.sql"


def _function_body(path: Path, name: str) -> str:
    sql = path.read_text(encoding="utf-8")
    pattern = re.compile(
        rf"create\s+or\s+replace\s+function\s+{re.escape(name)}\b"
        r".*?\bas\s+\$\$(.*?)\$\$\s*;",
        re.IGNORECASE | re.DOTALL,
    )
    match = pattern.search(sql)
    if match is None:
        raise AssertionError(f"{name} function body not found in {path.name}")
    return re.sub(r"\s+", " ", match.group(1)).lower()


def _compact(text: str) -> str:
    return re.sub(r"\s+", "", text).lower()


class FriendScheduleBlockSourceContractTest(unittest.TestCase):
    def test_block_helper_is_bidirectional(self) -> None:
        body = _compact(_function_body(PHASE8, "private.friend_is_blocked"))
        self.assertIn(
            "(b.blocker_user_id=p_viewerandb.blocked_user_id=p_owner)or"
            "(b.blocker_user_id=p_ownerandb.blocked_user_id=p_viewer)",
            body,
        )

    def test_public_schedule_rpc_uses_authenticated_viewer_and_block_gate(self) -> None:
        body = _compact(_function_body(PHASE8, "public.get_friend_schedule"))
        self.assertIn("declareactoruuid:=auth.uid()", body)
        self.assertIn("ifactorisnullthenraiseexception", body)
        self.assertIn(
            "allowed:=actor=p_owner_user_idor(not"
            "private.friend_is_blocked(actor,p_owner_user_id)andexists(",
            body,
        )
        self.assertIn("f.status='accepted'", body)
        self.assertIn(
            "private.build_friend_snapshot(actor,p_owner_user_id,p_term_id,p_range_start,p_range_end,allowed)",
            body,
        )

    def test_original_snapshot_base_denies_before_projection_and_filters_sources(self) -> None:
        body = _function_body(PHASE8, "private.build_friend_snapshot")
        denied = "if not p_allowed then return jsonb_build_object("
        self.assertIn(denied, body)
        self.assertLess(body.index(denied), body.index("owner_revision :="))
        self.assertIn("'allowed', false", body)
        self.assertIn("'revision', 0", body)
        self.assertIn("'owner_schedule_cursor', 0", body)
        self.assertIn("'items', '[]'::jsonb", body)
        self.assertGreaterEqual(body.count("not private.friend_is_blocked(p_viewer, p_owner)"), 3)
        self.assertIn("private.resolve_visible_events_for(p_viewer, p_range_start, p_range_end)", body)

    def test_phase15_event_projection_filters_blocked_owners(self) -> None:
        body = _compact(_function_body(PHASE8, "private.resolve_visible_events_for"))
        self.assertIn("notprivate.friend_is_blocked(p_viewer,e.owner_user_id)", body)

        phase15 = _compact(PHASE15.read_text(encoding="utf-8"))
        clone = "selectpg_get_functiondef('private.resolve_visible_events_for(uuid,timestamptz,timestamptz)'::regprocedure)intod"
        rename = "d:=replace(d,'private.resolve_visible_events_for(','private.phase15_resolve_visible_events_for_base(')"
        moderation = "d:=replace(d,'wheree.deleted_atisnull','wheree.deleted_atisnullande.moderation_hidden_atisnull')"
        wrapper = "createorreplacefunctionprivate.resolve_visible_events_for("
        self.assertLess(phase15.index(clone), phase15.index(rename))
        self.assertLess(phase15.index(rename), phase15.index(moderation))
        self.assertLess(phase15.index(moderation), phase15.index(wrapper))

    def test_safety_migration_preserves_base_then_denies_before_delegation(self) -> None:
        sql = SAFETY.read_text(encoding="utf-8").lower()
        clone = "select pg_get_functiondef('private.build_friend_snapshot(uuid,uuid,uuid,timestamptz,timestamptz,boolean)'::regprocedure) into d"
        rename = "d:=replace(d,'private.build_friend_snapshot(', 'private.phase15_build_friend_snapshot_base(')"
        event_clone = "select pg_get_functiondef('private.resolve_visible_events_for(uuid,timestamptz,timestamptz)'::regprocedure) into d"
        event_rename = "d:=replace(d,'private.resolve_visible_events_for(', 'private.phase15_resolve_visible_events_for_base(')"
        wrapper_start = "create or replace function private.build_friend_snapshot("
        self.assertLess(sql.index(clone), sql.index(rename))
        self.assertLess(sql.index(rename), sql.index(wrapper_start))
        self.assertLess(sql.index(event_clone), sql.index(event_rename))
        self.assertLess(sql.index(event_rename), sql.index(wrapper_start))

        wrapper = _function_body(SAFETY, "private.build_friend_snapshot")
        denied = "if not p_allowed or not private.safety_actor_active(p_viewer) or not private.safety_actor_active(p_owner) then"
        delegate = "return private.phase15_build_friend_snapshot_base(p_viewer,p_owner,p_term,p_range_start,p_range_end,p_allowed)"
        self.assertIn(denied, wrapper)
        self.assertIn("'allowed',false", re.sub(r"\s+", "", wrapper))
        self.assertIn("'items','[]'::jsonb", re.sub(r"\s+", "", wrapper))
        self.assertLess(wrapper.index(denied), wrapper.index(delegate))

    def test_private_projection_functions_are_not_client_executable(self) -> None:
        sql = SAFETY.read_text(encoding="utf-8").lower()
        self.assertIn(
            "revoke all on function private.build_friend_snapshot(uuid,uuid,uuid,timestamptz,timestamptz,boolean),",
            sql,
        )
        compact = _compact(sql)
        self.assertIn(
            "private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean),"
            "private.phase15_resolve_visible_events_for_base(uuid,timestamptz,timestamptz)frompublic,anon,authenticated,service_role",
            compact,
        )
        self.assertIn(
            "grantexecuteonfunctionprivate.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean),"
            "private.phase15_resolve_visible_events_for_base(uuid,timestamptz,timestamptz)topostgres,supabase_admin",
            compact,
        )

    def test_phase6_assignment_patch_targets_only_the_preserved_base(self) -> None:
        sql = PHASE6.read_text(encoding="utf-8").lower()
        self.assertIn("private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean)", sql)
        self.assertIn("if v_occurrences <> 1 then", sql)
        self.assertIn("execute replace(v_definition, v_old, v_new)", re.sub(r"\s+", " ", sql))
        self.assertIn("target_kind = 'event_kind' and r.target_value = 'assignment_deadline'", sql)
        normalized = re.sub(r"\s+", "", sql)
        self.assertIn(
            "revokeallonfunctionprivate.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean)frompublic,anon,authenticated,service_role",
            normalized,
        )

    def test_later_migrations_do_not_silently_redefine_the_guarded_functions(self) -> None:
        definitions: Counter[str] = Counter()
        projection_definitions: list[str] = []
        pattern = re.compile(r"create\s+or\s+replace\s+function\s+([\w.]+)", re.IGNORECASE)
        for path in sorted(MIGRATIONS.glob("*.sql")):
            names = [name.lower() for name in pattern.findall(path.read_text(encoding="utf-8"))]
            definitions.update(names)
            if "private.resolve_visible_events_for" in names:
                projection_definitions.append(path.name)
        self.assertEqual(definitions["private.friend_is_blocked"], 1)
        self.assertEqual(definitions["public.get_friend_schedule"], 1)
        self.assertEqual(definitions["private.build_friend_snapshot"], 2)
        self.assertEqual(projection_definitions, [
            PHASE8.name, PHASE15.name, SAFETY.name,
            VISIBILITY_PRECEDENCE.name, SAFETY_RESTORATION.name,
        ])
        self.assertEqual(definitions["private.resolve_visible_events_for"], len(projection_definitions))

    def test_final_visibility_wrapper_retains_safety_and_private_execution_boundary(self) -> None:
        body = _compact(_function_body(SAFETY_RESTORATION, "private.resolve_visible_events_for"))
        for required in (
            "private.phase15_resolve_visible_events_for_base(p_viewer,p_range_start,p_range_end)",
            "e.moderation_hidden_atisnull",
            "private.safety_actor_active(p_viewer)",
            "private.safety_actor_active(b.owner_user_id)",
            "b.group_idisnullorprivate.safety_group_active(b.group_id)",
        ):
            self.assertIn(required, body)
        sql = _compact(SAFETY_RESTORATION.read_text(encoding="utf-8"))
        self.assertIn(
            "revokeallonfunctionprivate.resolve_visible_events_for(uuid,timestamptz,timestamptz),"
            "private.phase15_resolve_visible_events_for_base(uuid,timestamptz,timestamptz)"
            "frompublic,anon,authenticated,service_role", sql,
        )


if __name__ == "__main__":
    unittest.main()
