FROM python:3.11-slim

RUN useradd -m appuser

WORKDIR /app

COPY main.py .

RUN pip install --no-cache-dir fastapi uvicorn

USER appuser

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
