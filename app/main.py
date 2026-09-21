from fastapi import FastAPI

app = FastAPI()
@app.get("/crms")
async def crms():
    return {"name": ""}

@app.get("/hello")
async def hello():
    return {"hello": "world"}