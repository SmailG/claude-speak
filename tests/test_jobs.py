import math
import multiprocessing as mp
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "daemon"))
from jobs import (CancelRing, JobBoard, MIN_QUEUE_AGE_S, RING_SIZE, SLOWEST_CHARS_PER_S,  # noqa: E402
                  StaleFilter, queue_age_limit)


class FakeClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def make_board(**kw) -> JobBoard:
    return JobBoard(CancelRing.create(mp.get_context("spawn")), **kw)


class JobBoardTest(unittest.TestCase):
    def test_other_session_is_queued_not_cancelled(self):
        board = make_board()
        a, b = board.submit("from A", "A"), board.submit("from B", "B")
        self.assertFalse(board.is_cancelled(a))
        self.assertEqual(board.next_job(timeout=0).id, a.id)
        self.assertEqual(board.next_job(timeout=0).id, b.id)

    def test_same_session_replaces_its_own_jobs(self):
        board = make_board()
        a1 = board.submit("A first", "A")
        self.assertEqual(board.next_job(timeout=0).id, a1.id)  # a1 is now playing
        b = board.submit("B", "B")
        a2 = board.submit("A second", "A")
        self.assertTrue(board.is_cancelled(a1))
        self.assertFalse(board.is_cancelled(b))
        self.assertEqual([board.next_job(timeout=0).id, board.next_job(timeout=0).id], [b.id, a2.id])

    def test_stop_from_session_cancels_only_that_session(self):
        board = make_board()
        a, b = board.submit("A", "A"), board.submit("B", "B")
        self.assertEqual(board.cancel_session("B"), 1)
        self.assertTrue(board.is_cancelled(b))
        self.assertFalse(board.is_cancelled(a))
        self.assertEqual(board.cancel_session("nobody"), 0)

    def test_stop_all_cancels_everything_including_playing(self):
        board = make_board()
        a = board.submit("A", "A")
        board.next_job(timeout=0)
        b = board.submit("B", "B")
        self.assertEqual(board.cancel_all(), 2)
        self.assertTrue(board.is_cancelled(a) and board.is_cancelled(b))
        self.assertIsNone(board.next_job(timeout=0))

    def test_generated_job_is_cancellable_while_its_audio_plays(self):
        clock = FakeClock()
        board = make_board(clock=clock)
        a = board.submit("A", "A")
        board.finish(board.next_job(timeout=0), audio_s=14.0)  # generated in <1 s, plays 14 s
        clock.now += 3
        self.assertEqual(board.cancel_session("A"), 1)
        self.assertTrue(board.is_cancelled(a))

    def test_stop_all_reaches_generated_jobs_still_playing(self):
        clock = FakeClock()
        board = make_board(clock=clock)
        a = board.submit("A", "A")
        board.finish(board.next_job(timeout=0), audio_s=14.0)
        clock.now += 3
        self.assertEqual(board.cancel_all(), 1)
        self.assertTrue(board.is_cancelled(a))

    def test_job_is_not_cancelled_after_its_audio_played(self):
        clock = FakeClock()
        board = make_board(clock=clock)
        a = board.submit("A", "A")
        board.finish(board.next_job(timeout=0), audio_s=2.0)
        clock.now += 60
        self.assertEqual(board.cancel_session("A"), 0)
        self.assertFalse(board.is_cancelled(a))

    def test_queued_audio_extends_the_later_jobs_play_window(self):
        clock = FakeClock()
        board = make_board(clock=clock)
        a, b = board.submit("A", "A"), board.submit("B", "B")
        board.finish(board.next_job(timeout=0), audio_s=20.0)
        board.finish(board.next_job(timeout=0), audio_s=5.0)  # B plays after A: ends at 25 s
        clock.now += 26  # A: 20 s + 5 s slack = 25 (over); B: 25 + 5 = 30 (still live)
        self.assertEqual(board.cancel_session("B"), 1)
        self.assertEqual(board.cancel_session("A"), 0)
        self.assertTrue(board.is_cancelled(b))
        self.assertFalse(board.is_cancelled(a))

    def test_stale_queued_job_is_dropped(self):
        clock = FakeClock()
        board = make_board(clock=clock, max_age_s=180)
        old = board.submit("old", "A")
        clock.now += 181
        fresh = board.submit("fresh", "B")
        self.assertEqual(board.next_job(timeout=0).id, fresh.id)
        self.assertTrue(board.is_cancelled(old))

    def test_job_keeps_its_own_wait_limit(self):
        clock = FakeClock()
        board = make_board(clock=clock, max_age_s=180)
        long_wait = board.submit("long limit", "A", max_age_s=600)
        short_wait = board.submit("default limit", "B")
        clock.now += 300
        self.assertEqual(board.next_job(timeout=0).id, long_wait.id)
        self.assertIsNone(board.next_job(timeout=0))
        self.assertTrue(board.is_cancelled(short_wait))

    def test_player_drops_a_reply_that_reaches_the_front_too_late(self):
        clock = FakeClock()
        stale = StaleFilter(clock=clock)
        expires_at = clock.now + 180
        clock.now += 181
        self.assertTrue(stale.is_stale(7, expires_at))
        self.assertTrue(stale.is_stale(7, expires_at))  # every later chunk of it too

    def test_player_finishes_a_reply_that_started_in_time(self):
        clock = FakeClock()
        stale = StaleFilter(clock=clock)
        expires_at = clock.now + 180
        clock.now += 170
        self.assertFalse(stale.is_stale(7, expires_at))
        clock.now += 60  # long reply: later chunks arrive past the limit
        self.assertFalse(stale.is_stale(7, expires_at))
        self.assertTrue(stale.is_stale(8, expires_at))  # but the next job is judged afresh

    def test_player_honours_a_long_per_job_limit(self):
        clock = FakeClock()
        stale = StaleFilter(clock=clock)
        clock.now += 500
        self.assertFalse(stale.is_stale(7, clock.now - 500 + queue_age_limit(10_000)))


class QueueAgeLimitTest(unittest.TestCase):
    def test_default_length_keeps_the_floor(self):
        self.assertEqual(queue_age_limit(2000), MIN_QUEUE_AGE_S)

    def test_long_limit_covers_one_full_reply_at_normal_speed(self):
        self.assertGreaterEqual(queue_age_limit(10_000), 10_000 / SLOWEST_CHARS_PER_S)
        self.assertGreater(queue_age_limit(10_000), queue_age_limit(5_000))

    def test_no_length_limit_never_drops(self):
        self.assertEqual(queue_age_limit(0), math.inf)

    def test_ring_wraps_without_false_positives(self):
        ring = CancelRing.create(mp.get_context("spawn"))
        for job_id in range(1, RING_SIZE + 6):
            ring.add(job_id)
        self.assertIn(RING_SIZE + 5, ring)
        self.assertNotIn(1, ring)       # overwritten by wrap-around
        self.assertNotIn(10_000, ring)  # never cancelled


if __name__ == "__main__":
    unittest.main()
