"""Coordinated username-request races against the isolated FRIEND-01 clone."""

from __future__ import annotations

import queue
import json
import subprocess
import threading
import time
import uuid


CONTAINER = "supabase_db_phase16_fresh_20260922"
DATABASE = "gpt6_friend_20260923_v2"
USERS = {
    "block_sender": "0f111111-1111-4111-8111-111111111111",
    "block_target": "0f222222-2222-4222-8222-222222222222",
    "optout_sender": "0f333333-3333-4333-8333-333333333333",
    "optout_target": "0f444444-4444-4444-8444-444444444444",
}


def _psql_args() -> list[str]:
    return [
        "docker", "exec", "-i", CONTAINER, "psql", "-X", "-qAt",
        "-v", "ON_ERROR_STOP=on", "-U", "supabase_admin", "-d", DATABASE,
    ]


def admin(sql: str) -> str:
    result = subprocess.run(
        _psql_args(), input=sql, text=True, capture_output=True, check=False
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "isolated database command failed")
    return result.stdout.strip()


class Session:
    def __init__(self, user_id: str, name: str = "race") -> None:
        self.process = subprocess.Popen(
            _psql_args(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        self.lines: queue.Queue[str] = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()
        self.execute(
            f"set application_name = 'friend_username_race_{name}'; "
            f"set request.jwt.claim.sub = '{user_id}'; "
            f"set request.jwt.claim.role = 'authenticated'; "
            f"set request.jwt.claims = '{{\"sub\":\"{user_id}\",\"role\":\"authenticated\"}}'; "
            "set role authenticated;"
        )

    def _read(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self.lines.put(line.rstrip())

    def execute(self, sql: str) -> list[str]:
        marker = f"__DONE_{uuid.uuid4().hex}__"
        self.send(sql, marker)
        return self.wait(marker)

    def send(self, sql: str, marker: str | None = None) -> str:
        marker = marker or f"__DONE_{uuid.uuid4().hex}__"
        assert self.process.stdin is not None
        self.process.stdin.write(sql + f"\n\\echo {marker}\n")
        self.process.stdin.flush()
        return marker

    def wait(self, marker: str) -> list[str]:
        output: list[str] = []
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                line = self.lines.get(timeout=0.2)
            except queue.Empty:
                if self.process.poll() is not None:
                    tail = list(self.lines.queue)
                    raise RuntimeError(
                        "race session exited unexpectedly: " + " | ".join(tail)
                    )
                continue
            if marker in line:
                return output
            output.append(line)
        raise TimeoutError("race session did not finish its SQL command")

    def close(self) -> None:
        if self.process.poll() is None:
            assert self.process.stdin is not None
            self.process.stdin.write("reset role;\n\\q\n")
            self.process.stdin.flush()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()


def _wait_for_advisory_waiters(expected: int) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        state = admin(
            "select count(*) filter (where wait_event_type='Lock' and wait_event='advisory'), "
            "count(*) filter (where state='active') "
            "from pg_stat_activity where application_name like 'friend_username_race_%';"
        )
        waiting, active = (int(value) for value in state.split('|'))
        if active >= expected and waiting >= 1:
            return
        time.sleep(0.05)
    details = admin(
        "select coalesce(string_agg(state||':'||coalesce(wait_event,'-')||':'||left(query,100), E'\\n'), '') "
        "from pg_stat_activity where application_name like 'friend_username_race_%';"
    )
    raise TimeoutError(f"advisory wait state={state}; sessions={details}")


def _wait_for_optout_waiter() -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        state = admin(
            "select count(*) filter (where wait_event_type='Lock' and state='active' "
            "and query ilike '%set_my_friend_username%'), count(*) "
            "from pg_stat_activity where application_name like 'friend_username_race_%';"
        )
        waiting, active = (int(value) for value in state.split('|'))
        if active >= 1 and waiting == 1:
            return
        time.sleep(0.05)
    details = admin(
        "select coalesce(string_agg(state||':'||coalesce(wait_event,'-')||':'||left(query,100), E'\\n'), '') "
        "from pg_stat_activity where application_name like 'friend_username_race_%';"
    )
    raise TimeoutError(f"row-lock wait state={state}; sessions={details}")


def _hold_lock(statement: str) -> Session:
    session = Session(USERS["block_sender"], "block_lock")
    session.execute("reset role; begin;")
    session.execute(statement)
    return session


def _cleanup() -> None:
    ids = ",".join(f"'{value}'::uuid" for value in USERS.values())
    admin(f"""
      delete from public.friend_visibility_rules where owner_user_id in ({ids}) or friend_user_id in ({ids});
      delete from public.friendships where requester_user_id in ({ids}) or addressee_user_id in ({ids});
      delete from public.blocks where blocker_user_id in ({ids}) or blocked_user_id in ({ids});
      delete from public.friend_invites where issuer_user_id in ({ids}) or claimed_by in ({ids});
      delete from private.friend_operation_receipts where actor_user_id in ({ids});
      delete from public.friend_schedule_revisions where owner_user_id in ({ids});
      delete from auth.users where id in ({ids});
    """)


def _request_outcome(target_id: str, username: str, operation_id: str) -> str:
    return f"""do $$ begin
      begin
        perform public.request_friend_by_username(
          '{target_id}', '{username}', '{operation_id}'
        );
        raise notice 'RACE_RESULT=request_succeeded';
      exception when sqlstate '42501' then
        raise notice 'RACE_RESULT=request_unavailable';
      end;
    end $$;"""


def _result(lines: list[str], expected: set[str]) -> str:
    matches = [line.rsplit("RACE_RESULT=", 1)[1]
               for line in lines if "RACE_RESULT=" in line]
    if len(matches) != 1 or matches[0] not in expected:
        raise AssertionError(f"unexpected race outcome: {lines!r}")
    return matches[0]


def _json_result(lines: list[str]) -> dict[str, object]:
    values = [json.loads(line) for line in lines if line.lstrip().startswith("{")]
    if len(values) != 1 or not isinstance(values[0], dict):
        raise AssertionError(f"expected one JSON result, got: {lines!r}")
    return values[0]


def _set_username(user_id: str, username: str, searchable: bool) -> list[str]:
    session = Session(user_id, "profile_setup")
    try:
        lines = session.execute(
            f"select public.set_my_friend_username('{username}',{str(searchable).lower()});"
        )
        result = _json_result(lines)
        if result != {
            "username": username,
            "searchable_by_username": searchable,
        }:
            raise AssertionError(f"profile setup returned unexpected result: {result!r}")
        return lines
    finally:
        session.close()


def main() -> None:
    print(f"TARGET isolated clone: container={CONTAINER}, database={DATABASE}")
    inserted = ",".join(f"('{value}')" for value in USERS.values())
    user_list = ",".join(f"'{value}'::uuid" for value in USERS.values())
    if admin(f"select count(*) from auth.users where id in ({user_list});") != "0":
        raise RuntimeError("reserved FRIEND-01 race fixture ids already exist; refusing to overwrite them")
    sessions: list[Session] = []
    try:
        admin(f"""
          insert into auth.users(id) values {inserted};
          update public.profiles set username=null, searchable_by_username=false, deleted_at=null
          where user_id in ({user_list});
          update public.profiles set username='race_block_target', searchable_by_username=true
          where user_id='{USERS['block_target']}';
          update public.profiles set username='race_optout_target', searchable_by_username=true
          where user_id='{USERS['optout_target']}';
        """)

        block_pair = ":".join(sorted([USERS["block_sender"], USERS["block_target"]]))
        blocker = _hold_lock(
            f"select pg_advisory_xact_lock(hashtextextended('{block_pair}',8108));"
        )
        sessions.append(blocker)
        request = Session(USERS["block_sender"], "block_request")
        block = Session(USERS["block_sender"], "block_action")
        sessions += [request, block]
        request_marker = request.send(
            _request_outcome(
                USERS["block_target"], "race_block_target",
                "0faaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1",
            )
        )
        block_marker = block.send(
            f"select public.block_user('{USERS['block_target']}',"
            f"'0faaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2');"
        )
        _wait_for_advisory_waiters(2)
        blocker.execute("commit;")
        request_outcome = _result(
            request.wait(request_marker),
            {"request_succeeded", "request_unavailable"},
        )
        block_output = block.wait(block_marker)
        block_result = _json_result(block_output)
        if block_result.get("blocked") is not True or block_result.get("user_id") != USERS["block_target"]:
            raise AssertionError(f"block operation returned unexpected result: {block_result!r}")
        block.close()
        blocker.close()
        sessions.remove(blocker)
        if admin(
            f"select count(*) from public.friendships where "
            f"least(requester_user_id,addressee_user_id)=least('{USERS['block_sender']}'::uuid,'{USERS['block_target']}'::uuid) "
            f"and greatest(requester_user_id,addressee_user_id)=greatest('{USERS['block_sender']}'::uuid,'{USERS['block_target']}'::uuid) "
            "and status in ('pending','accepted');"
        ) != "0":
            raise AssertionError("a block/request race left an actionable relationship")
        if admin(
            f"select count(*) from public.blocks where blocker_user_id='{USERS['block_sender']}' "
            f"and blocked_user_id='{USERS['block_target']}';"
        ) != "1":
            raise AssertionError("block/request race did not commit the block")
        print(f"PASS request/block race; request={request_outcome}, block succeeded, no actionable relationship")

        # Ordering A: a committed opt-out before confirmation must reject the
        # request and leave no relationship row behind.
        optout_setup = _set_username(
            USERS["optout_target"], "race_optout_target", False
        )
        request = Session(USERS["optout_sender"], "optout_first_request")
        sessions.append(request)
        result = request.execute(_request_outcome(
            USERS["optout_target"], "race_optout_target",
            "0faaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3",
        ))
        if _result(result, {"request_unavailable"}) != "request_unavailable":
            raise AssertionError("request succeeded after the target committed opt-out")
        request.close()
        sessions.remove(request)
        if admin(
            f"select count(*) from public.friendships where "
            f"least(requester_user_id,addressee_user_id)=least('{USERS['optout_sender']}'::uuid,'{USERS['optout_target']}'::uuid) "
            f"and greatest(requester_user_id,addressee_user_id)=greatest('{USERS['optout_sender']}'::uuid,'{USERS['optout_target']}'::uuid);"
        ) != "0":
            raise AssertionError("opt-out-first confirmation created a relationship")
        print("PASS committed opt-out before confirmation rejects request with no relationship")

        optin_setup = _set_username(
            USERS["optout_target"], "race_optout_target", True
        )
        # Ordering B: keep the successful request transaction open after the
        # RPC returns. Its eligibility row locks must make opt-out wait until
        # the request commits; both operations must then complete successfully.
        request = Session(USERS["optout_sender"], "request_first")
        optout = Session(USERS["optout_target"], "request_first_optout")
        sessions += [request, optout]
        request.execute("begin;")
        request_result = request.execute(
            f"select public.request_friend_by_username('{USERS['optout_target']}',"
            f"'race_optout_target','0faaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4');"
        )
        request_value = _json_result(request_result)
        if request_value.get("status") != "pending":
            raise AssertionError(f"request-first RPC did not return pending success: {request_value!r}")
        optout_marker = optout.send(
            "select public.set_my_friend_username('race_optout_target',false);"
        )
        _wait_for_optout_waiter()
        # Prove the wait is on the eligible profile row itself. An advisory
        # wait can be caused by unrelated lifecycle/revision locks, so inspect
        # the exact row under NOWAIT while the request transaction is open.
        profile_probe = Session(USERS["optout_target"], "profile_lock_probe")
        sessions.append(profile_probe)
        probe = profile_probe.execute(f"""do $$ begin
          begin
            perform 1 from public.profiles
            where user_id='{USERS['optout_target']}' for update nowait;
            raise notice 'FRIEND_PROFILE_LOCK=acquired';
          exception when lock_not_available then
            raise notice 'FRIEND_PROFILE_LOCK=blocked';
          end;
        end $$;""")
        lock_results = [line.rsplit("FRIEND_PROFILE_LOCK=", 1)[1]
                        for line in probe if "FRIEND_PROFILE_LOCK=" in line]
        if lock_results != ["blocked"]:
            raise AssertionError(
                f"request did not hold the target profile row lock: {probe!r}"
            )
        profile_probe.close()
        sessions.remove(profile_probe)
        request.execute("commit;")
        optout_result = optout.wait(optout_marker)
        if _json_result(optout_result).get("searchable_by_username") is not False:
            raise AssertionError(f"opt-out returned unexpected result: {optout_result!r}")
        request.close()
        optout.close()
        sessions.remove(request)
        sessions.remove(optout)
        if admin(
            f"select searchable_by_username::text from public.profiles where user_id='{USERS['optout_target']}';"
        ) != "false":
            raise AssertionError("request-first race did not finish with the committed opt-out")
        live = admin(
            f"select count(*) from public.friendships where "
            f"least(requester_user_id,addressee_user_id)=least('{USERS['optout_sender']}'::uuid,'{USERS['optout_target']}'::uuid) "
            f"and greatest(requester_user_id,addressee_user_id)=greatest('{USERS['optout_sender']}'::uuid,'{USERS['optout_target']}'::uuid) "
            "and status in ('pending','accepted');"
        )
        if live != "1":
            raise AssertionError(f"request-first/opt-out-second lost the successful pending request: count={live}")
        print("PASS request holds eligibility locks; opt-out waits; both commit and pending request remains")
    finally:
        for session in sessions:
            session.close()
        _cleanup()


if __name__ == "__main__":
    main()
