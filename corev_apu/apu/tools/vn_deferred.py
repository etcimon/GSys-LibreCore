#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Deferred native control replies; no success before a continuation completes."""


class DeferredReply:
    def __init__(self, task, finish):
        self.task, self.finish = task, finish

    def poll(self):
        if self.task.terminal:
            return self.finish(self.task)
        return None
