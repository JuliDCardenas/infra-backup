import json
import ssl
import time
import os

import paho.mqtt.client as mqtt
import psycopg

MQTT_HOST = os.getenv("MQTT_HOST", "mqtt.julidcardenas.site")
MQTT_PORT = int(os.getenv("MQTT_PORT", "8883"))
MQTT_USER = os.getenv("MQTT_USER", "")
MQTT_PASS = os.getenv("MQTT_PASS", "")
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "tracker/KZX003/imu/tilt")

DEVICE_ID_DEFAULT = os.getenv("DEVICE_ID", "KZX003")

PGHOST = os.getenv("PGHOST", "mqtt-postgres")
PGPORT = int(os.getenv("PGPORT", "5432"))
PGDATABASE = os.getenv("PGDATABASE", "")
PGUSER = os.getenv("PGUSER", "")
PGPASSWORD = os.getenv("PGPASSWORD", "")

# MVP: similar a usar `--insecure` en mosquitto_sub (NO recomendado para producción)
MQTT_TLS_INSECURE = os.getenv("MQTT_TLS_INSECURE", "true").lower() == "true"


def pg_connect():
	return psycopg.connect(
		host=PGHOST,
		port=PGPORT,
		dbname=PGDATABASE,
		user=PGUSER,
		password=PGPASSWORD,
	)


conn = None


def on_connect(client, userdata, flags, rc):
	print(f"[MQTT] connect rc={rc}")
	client.subscribe(MQTT_TOPIC, qos=0)
	print(f"[MQTT] subscribed {MQTT_TOPIC}")


def on_message(client, userdata, msg):
	global conn
	payload = msg.payload.decode("utf-8", errors="replace")

	try:
		data = json.loads(payload)
		t_ms = int(data["t_ms"])
		roll = float(data["roll"])
		pitch = float(data["pitch"])
	except Exception as e:
		print(f"[PARSE] fail: {e} payload={payload}")
		return

	device_id = DEVICE_ID_DEFAULT

	try:
		with conn.cursor() as cur:
			cur.execute(
				"""
				INSERT INTO imu_tilt (device_id, topic, t_ms, roll, pitch)
				VALUES (%s, %s, %s, %s, %s)
				""",
				(device_id, msg.topic, t_ms, roll, pitch),
			)
		print(f"[DB] insert ok t_ms={t_ms} roll={roll} pitch={pitch}")
	except Exception as e:
		print(f"[DB] insert fail: {e}")
		# intento simple de reconexión
		time.sleep(1)
		conn = pg_connect()


def main():
	global conn
	conn = pg_connect()
	conn.autocommit = True

	client = mqtt.Client()
	client.username_pw_set(MQTT_USER, MQTT_PASS)

	if MQTT_TLS_INSECURE:
		client.tls_set(cert_reqs=ssl.CERT_NONE)
		client.tls_insecure_set(True)
	else:
		client.tls_set()

	client.on_connect = on_connect
	client.on_message = on_message

	print(f"[MQTT] connecting {MQTT_HOST}:{MQTT_PORT} ...")
	client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
	client.loop_forever()


if __name__ == "__main__":
	main()
