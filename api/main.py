import asyncio
import logging
import os

from fastapi import FastAPI, HTTPException
from fastapi.responses import RedirectResponse
from dotenv import load_dotenv
from repositories.postgres_repository import PostgresDB
from routers.journal_router import router as journal_router

load_dotenv()

logging.basicConfig(
    level=os.getenv("APP_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("journal")

app = FastAPI(title="LearningSteps API - Release 2 Olehs Limited Edition", description="A simple learning journal API for tracking daily work, struggles, and intentions")
app.include_router(journal_router)
logger.info("LearningSteps application initialized")


@app.get("/health/live", include_in_schema=False)
async def liveness():
    """Check that the application responds, independently of PostgreSQL."""
    return {"status": "ok"}


async def check_database():
    async with PostgresDB() as db:
        async with db.pool.acquire() as connection:
            await connection.fetchval("SELECT 1")


@app.get("/health/ready", include_in_schema=False)
async def readiness():
    """Admit traffic only when the application can query PostgreSQL."""
    try:
        await asyncio.wait_for(check_database(), timeout=3.0)
    except Exception:
        logger.warning("Database readiness check failed")
        raise HTTPException(status_code=503, detail="Database unavailable")
    return {"status": "ready"}


@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse(url="/docs")
