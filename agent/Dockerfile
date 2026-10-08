# Day 26：行銷助理的容器映像檔，由 scripts/deploy_assistant.sh 建置
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 只放服務用得到的四樣東西，測試程式與 SQL 不進映像檔
COPY serve.py tools.py guard.py ./
COPY static ./static
RUN useradd --create-home appuser
USER appuser

# 對話紀錄與每日花費都記在記憶體裡，所以只能有一個 worker，要同時處理幾個請求靠 thread
CMD exec gunicorn --bind :$PORT --workers 1 --threads 4 --timeout 300 serve:app
