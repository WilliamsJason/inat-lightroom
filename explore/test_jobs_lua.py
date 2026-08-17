"""Tests for Jobs.lua -- one long iNaturalist operation at a time.

The operations this guards all walk the catalog and write to it. Two at once
contend for write transactions and, worse, a reverse sync deciding which photos
are free to link while a sync is busy linking them is reading a catalog that is
changing underneath it.

Most of what follows is about the lock being released. A job that fails without
releasing leaves the plugin refusing to do anything at all until Lightroom is
restarted, with nothing on screen to say why -- a worse outcome than the
overlapping runs the lock exists to prevent.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def jobs(plugin):
    return plugin.require("Jobs")


# ------------------------------------------------------------------ the lock

def test_a_job_runs_when_nothing_else_is(plugin, jobs):
    ran = []

    assert jobs.run("Syncing", lambda: ran.append(True)) is True
    assert ran == [True]


def test_a_second_job_is_refused_while_the_first_runs(plugin, jobs):
    """The whole point. Nested here because that is the only way to observe
    the lock actually held rather than merely set and cleared."""
    inner = []

    def outer():
        ran, _blocking = jobs.run("Reverse sync", lambda: inner.append("ran"))
        inner.append(ran)

    jobs.run("Syncing", outer)

    assert inner == [False]


def test_the_blocker_is_named(plugin, jobs):
    """So the message can say what to wait for rather than just "busy"."""
    seen = {}

    def outer():
        ran, blocking = jobs.run("Reverse sync", lambda: None)
        seen["ran"], seen["blocking"] = ran, blocking

    jobs.run("Syncing all linked photos", outer)

    assert seen["ran"] is False
    assert seen["blocking"] == "Syncing all linked photos"


def test_the_lock_is_free_again_afterwards(plugin, jobs):
    jobs.run("Syncing", lambda: None)

    assert jobs.isRunning() is False
    assert jobs.run("Reverse sync", lambda: None) is True


def test_a_failing_job_still_releases_the_lock(plugin, jobs):
    """Otherwise one error bricks the plugin until Lightroom restarts, and
    nothing on screen explains it."""
    def boom():
        raise RuntimeError("network died")

    with pytest.raises(Exception):
        jobs.run("Syncing", boom)

    assert jobs.isRunning() is False
    assert jobs.run("Reverse sync", lambda: None) is True


def test_a_failing_job_still_reports_its_failure(plugin, jobs):
    """Releasing the lock must not swallow the error on the way out."""
    def boom():
        error = plugin.eval('function() error("network died", 0) end')
        error()

    with pytest.raises(Exception) as caught:
        jobs.run("Syncing", boom)

    assert "network died" in str(caught.value)


# --------------------------------------------------------------- reporting

def test_being_blocked_tells_the_user_what_is_running(plugin, jobs):
    def outer():
        jobs.runOrReport("Reverse sync", lambda: None)

    jobs.run("Syncing all linked photos", outer)

    shown = plugin.dialogs[-1]
    assert "Syncing all linked photos" in shown["message"]
    assert "cancel it from the progress bar" in shown["message"]


def test_a_job_that_runs_says_nothing(plugin, jobs):
    jobs.runOrReport("Syncing", lambda: None)

    assert plugin.dialogs == []


# ---------------------------------------------------------------- watchers

def test_a_watcher_hears_the_current_state_immediately(plugin, jobs):
    """So a dialog opened during a sync started from the menu comes up with
    its buttons already greyed, rather than offering a second one."""
    seen = []

    def outer():
        jobs.watch(plugin.eval("{}"), lambda running: seen.append(running))

    jobs.run("Syncing", outer)

    # And then told again when that job ended, since it stays registered.
    assert seen == ["Syncing", None]


def test_a_watcher_is_told_when_a_job_starts_and_ends(plugin, jobs):
    seen = []
    jobs.watch(plugin.eval("{}"), lambda running: seen.append(running))

    jobs.run("Syncing", lambda: None)

    assert seen == [None, "Syncing", None]


def test_a_broken_watcher_does_not_take_down_the_job(plugin, jobs):
    """A dismissed dialog's property table is the expected case here, and a
    button failing to grey out must not abort the sync it was describing."""
    def explode(_running):
        raise RuntimeError("property table is dead")

    jobs.watch(plugin.eval("{}"), explode)
    ran = []

    assert jobs.run("Syncing", lambda: ran.append(True)) is True
    assert ran == [True]
    assert jobs.isRunning() is False
