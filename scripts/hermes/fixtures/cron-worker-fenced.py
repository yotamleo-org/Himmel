# Verbatim copy of _run_external_worker_payload from NousResearch/hermes-agent
# 521f4dc2a1a4e19d56419a899f779d60efa01716:cron/scheduler.py (MIT License, Copyright (c) 2025 Nous Research).
# After the fix (946eafdf2fe): the worker registers the profile config hooks.

def _run_external_worker_payload(payload_path: Path, ack_path: Path) -> bool:
    """Adopt and execute one gateway-dispatched cron payload.

    The execution row is created by the gateway before spawn, then transferred
    here before the ready acknowledgement is published.  No side effect runs
    unless that durable ownership transfer succeeds.
    """
    try:
        payload = json.loads(payload_path.read_text(encoding="utf-8-sig"))
        job = payload["job"]
        profile_home = Path(payload["profile_home"]).resolve()
        execution_id = str(job["execution_id"])
    except Exception:
        logger.exception("Cron external worker could not load payload %s", payload_path)
        return False
    finally:
        try:
            payload_path.unlink(missing_ok=True)
        except OSError:
            pass

    from agent.secret_scope import (
        build_profile_secret_scope,
        is_multiplex_active,
        reset_secret_scope,
        set_multiplex_active,
        set_secret_scope,
    )
    from cron.executions import adopt_claimed_execution
    from hermes_cli.env_loader import hydrate_profile_secret_sources
    from hermes_constants import (
        reset_hermes_home_override,
        set_hermes_home_override,
    )

    previous_multiplex = is_multiplex_active()
    home_token = secret_token = None
    try:
        home_token = set_hermes_home_override(profile_home)
        multiplex_active = bool(payload.get("multiplex_active", False))
        set_multiplex_active(multiplex_active)
        # Plugin secret sources (``ctx.register_secret_source()``) only exist after plugin
        # discovery; this process starts with the builtin registry alone, so hydrating without it
        # silently dropped every plugin-sourced credential (#121929). Runs under the home override
        # so a multiplexed worker loads the OWNING profile's plugins, not the launch profile's.
        from hermes_cli.plugins import discover_plugins

        discover_plugins()
        hydrate_profile_secret_sources(profile_home)
        secret_token = set_secret_scope(build_profile_secret_scope(profile_home), profile_home=str(profile_home))
        # This process never ran gateway startup, so the OWNING profile's ``hooks:`` block (shell
        # hooks + ``hooks.outbound``) was never registered and cron sessions silently lost it
        # (#131764). Same helper the gateway uses per profile; it must run inside the secret scope
        # because ``secret_env`` targets resolve through ``get_secret`` (raises unscoped under multiplex).
        from gateway.run_startup import GatewayStartupMixin

        GatewayStartupMixin._register_config_hooks(
            "Cron external worker: config hook registration failed", level=logging.WARNING)
        with use_cron_store(profile_home):
            if adopt_claimed_execution(execution_id) is None:
                logger.error(
                    "Cron external worker refused execution %s: durable ownership "
                    "could not be established",
                    execution_id,
                )
                return False
            try:
                ack_path.parent.mkdir(parents=True, exist_ok=True)
                # Publish via write-to-temp + atomic rename. Writing ack_path in place
                # (the old approach) let O_CREAT make the empty file visible to the
                # scheduler's exists()-then-read polling loop before the JSON body was
                # written, occasionally handing it a 0-byte file and a JSONDecodeError.
                # os.replace() is a single atomic syscall on the same filesystem, so
                # readers only ever see the file fully absent or fully written.
                ack_tmp_path = ack_path.with_name(f"{ack_path.name}.tmp{os.getpid()}")
                fd = os.open(ack_tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as ack_file:
                        json.dump({"pid": os.getpid(), "execution_id": execution_id}, ack_file)
                        ack_file.flush()
                        os.fsync(ack_file.fileno())
                    os.replace(ack_tmp_path, ack_path)
                except BaseException:
                    ack_tmp_path.unlink(missing_ok=True)
                    raise
            except Exception:
                logger.exception(
                    "Cron external worker could not publish ready acknowledgement for %s",
                    execution_id,
                )
                return False
            old_external_execution = os.environ.get("_HERMES_CRON_EXTERNAL_WORKER")
            os.environ["_HERMES_CRON_EXTERNAL_WORKER"] = execution_id
            try:
                completed = run_one_job(job, adapters=None, loop=None, verbose=False)
                # Successful return: the worker recorded its outcome. If it raises,
                # retain fd 2's pathname until the waiter consumes the traceback.
                with contextlib.suppress(OSError):
                    ack_path.with_suffix(".stderr").unlink(missing_ok=True)
                return completed
            finally:
                if old_external_execution is None:
                    os.environ.pop("_HERMES_CRON_EXTERNAL_WORKER", None)
                else:
                    os.environ["_HERMES_CRON_EXTERNAL_WORKER"] = old_external_execution
    finally:
        if secret_token is not None:
            reset_secret_scope(secret_token)
        set_multiplex_active(previous_multiplex)
        if home_token is not None:
            reset_hermes_home_override(home_token)
