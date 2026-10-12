"""Static guard for the group-availability nonmember authorization case.

This checks source and test wiring only. It does not execute PostgreSQL and
does not replace isolated pgTAP/Auth runtime acceptance.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SAFETY_MIGRATION = (
    ROOT / "supabase/migrations/20260923064500_safety_moderation_enforcement.sql"
)
PGTAP = ROOT / "supabase/tests/group_availability.sql"


def _function_body(sql: str, name: str) -> str:
    match = re.search(
        rf"create\s+or\s+replace\s+function\s+{re.escape(name)}\b"
        r".*?\bas\s+\$\$(.*?)\$\$\s*;",
        sql,
        re.IGNORECASE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"{name} definition not found")
    return re.sub(r"\s+", " ", match.group(1)).lower()


class GroupAvailabilityNonmemberSourceContractTest(unittest.TestCase):
    def test_wrapper_rejects_nonmember_actor_before_base_projection(self) -> None:
        sql = SAFETY_MIGRATION.read_text(encoding="utf-8")
        body = _function_body(sql, "public.find_group_availability")
        compact = re.sub(r"\s+", "", body)
        actor_gate = (
            "ifactorisnullorp_member_idsisnullornot(actor=any(p_member_ids))"
            "ornotprivate.group_member(p_group_id,actor)then"
            "raiseexception'membershiporauthorizationchanged;retry'"
            "usingerrcode='42501';endif;"
        )
        member_gate = (
            "foreachmember_idinarrayp_member_idsloop"
            "ifnotprivate.group_member(p_group_id,member_id)then"
            "raiseexception'membershiporauthorizationchanged;retry'"
            "usingerrcode='42501';endif;endloop;"
        )
        delegation = "returnprivate.phase12_find_group_availability_base("
        self.assertIn(actor_gate, compact)
        self.assertIn(member_gate, compact)
        self.assertLess(compact.index(actor_gate), compact.index(delegation))
        self.assertLess(compact.index(member_gate), compact.index(delegation))

    def test_pgtap_invokes_rpc_as_nonmember_with_valid_group_member_id(self) -> None:
        sql = PGTAP.read_text(encoding="utf-8").lower()
        compact = re.sub(r"\s+", " ", sql)
        self.assertIn("select extensions.plan(36);", compact)
        self.assertIn("'availability outsider'", compact)
        group_members = compact.split("insert into public.group_members", 1)[1].split(
            "insert into public.calendars", 1
        )
        self.assertEqual(len(group_members), 2)
        self.assertNotIn("9a444444-4444-4444-8444-444444444444", group_members[0])

        claim_marker = (
            "set local request.jwt.claim.sub="
            "'9a444444-4444-4444-8444-444444444444'"
        )
        claim_start = compact.index(claim_marker)
        claim_end = compact.index("reset role;", claim_start)
        nonmember_block = compact[claim_start:claim_end]
        self.assertIn("set local role authenticated;", nonmember_block)
        self.assertIn(
            "array['9a111111-1111-4111-8111-111111111111'::uuid]",
            nonmember_block,
        )
        self.assertIn(
            "array['9a444444-4444-4444-8444-444444444444'::uuid]",
            nonmember_block,
        )
        for assertion in (
            "'42501','membership or authorization changed; retry',"
            "'nonmember cannot read group availability'",
            "'nonmember actor fails group membership gate when selected'",
        ):
            self.assertIn(assertion, nonmember_block)


if __name__ == "__main__":
    unittest.main()
