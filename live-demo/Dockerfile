FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN useradd --create-home appuser
USER appuser

# Cloud Run 會注入 PORT；單一 worker 多 thread 足以應付 Demo 流量，也最省記憶體
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 0 main:app
