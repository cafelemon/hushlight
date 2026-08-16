from functools import lru_cache

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from .engine import CompanionEngine


app = FastAPI(title="Hushlight Local LLM API", version="0.1.0")


class CompanionRequest(BaseModel):
    user_text: str = Field(min_length=1, max_length=4000)


@lru_cache(maxsize=1)
def get_engine() -> CompanionEngine:
    return CompanionEngine()


@app.get("/health")
def health() -> dict[str, object]:
    engine = get_engine()
    return {
        "status": "ready" if engine.is_downloaded else "model_missing",
        "model_id": engine.config["model_id"],
        "model_path": str(engine.model_path),
    }


@app.post("/v1/companion/respond")
def respond(request: CompanionRequest) -> dict[str, object]:
    try:
        result = get_engine().infer(request.user_text)
    except (FileNotFoundError, ValueError, RuntimeError) as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    return {
        "model_id": get_engine().config["model_id"],
        **result.to_dict(),
    }

