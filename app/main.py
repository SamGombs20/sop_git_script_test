from fastapi import FastAPI

app = FastAPI()

@app.get("/")
def root():
    return {"status":"ok"}

@app.get("/greetings")
def greetings():
    return {"greeting":"Hello there"}

@app.get("/crms")
async def crms():
    return {"name": ""}