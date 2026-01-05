from fastapi import FastAPI

app = FastAPI()

@app.get("/")
def root():
    return {"status": "running", "message": "GKE app deployed securely using Terraform + OIDC"}

@app.get("/health")
def health():
    return {"health": "ok"}
