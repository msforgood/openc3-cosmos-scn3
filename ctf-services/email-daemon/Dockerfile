FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY email_daemon.py .

CMD ["python", "-u", "email_daemon.py"]
