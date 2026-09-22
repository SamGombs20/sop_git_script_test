import uvicorn
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

@app.get("/hello")
async def hello():
    return {"hello": "world"}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)