"""Run from the repository root; no live PostgreSQL connection is required."""

import os
from pathlib import Path
import sys


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "api"))
# Import-time configuration only. All database calls are replaced by test doubles.
os.environ["DATABASE_URL"] = (
    "postgresql://test:test@127.0.0.1:5432/learningsteps_test"
)
