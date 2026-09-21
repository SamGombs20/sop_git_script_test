from fastapi import FastAPI

app = FastAPI()
@app.get("/crms")
async def crms():
    return {"name": ""}