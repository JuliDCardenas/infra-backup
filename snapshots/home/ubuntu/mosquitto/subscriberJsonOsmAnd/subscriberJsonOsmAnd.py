import os
import time
import logging
import requests
import paho.mqtt.client as mqtt

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)

# ---------- MQTT ----------
MQTT_HOST = os.getenv("MQTT_HOST", "mqtt.julidcardenas.site")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_USER = os.getenv("MQTT_USER", "")
MQTT_PASS = os.getenv("MQTT_PASS", "")
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "tracker/Lilygo/telemetria")

# ---------- TRACCAR (OsmAnd) ----------
TRACCAR_HOST = os.getenv("TRACCAR_HOST", "traccar.julidcardenas.site")
TRACCAR_PORT = int(os.getenv("TRACCAR_PORT", "5055"))
# Si no lo pasas, usa el device_id que venga en el CSV
TRACCAR_DEVICE_ID_FALLBACK = os.getenv("TRACCAR_DEVICE_ID", "")

# ---------- CONTROL ----------
MIN_INTERVAL_SEC = float(os.getenv("MIN_INTERVAL_SEC", "10"))
MIN_MOVE_METERS = float(os.getenv("MIN_MOVE_METERS", "20"))
HTTP_TIMEOUT_SEC = float(os.getenv("HTTP_TIMEOUT_SEC", "5"))

_last_sent_ts = 0.0
_last_lat = None
_last_lon = None

def haversine_m(lat1, lon1, lat2, lon2):
    from math import radians, sin, cos, sqrt, atan2
    R = 6371000.0
    p1, p2 = radians(lat1), radians(lat2)
    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)
    a = sin(dlat / 2) ** 2 + cos(p1) * cos(p2) * sin(dlon / 2) ** 2
    c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return R * c


def should_send(lat, lon):
    global _last_sent_ts, _last_lat, _last_lon
    now = time.time()

    if now - _last_sent_ts < MIN_INTERVAL_SEC:
        return False, "rate_limit"

    if _last_lat is not None and _last_lon is not None:
        dist = haversine_m(_last_lat, _last_lon, lat, lon)
        if dist < MIN_MOVE_METERS:
            return False, f"no_move_{dist:.1f}m"

    return True, "ok"


def send_osmand(device_id, lat, lon, speed=None, alt=None):
    params = {
        "id": device_id,
        "lat": f"{lat:.5f}",
        "lon": f"{lon:.5f}",
    }
    # Traccar OsmAnd espera speed típicamente en km/h; si ves raro, ajustamos
    if speed is not None:
        params["speed"] = f"{float(speed):.1f}"
    if alt is not None:
        params["altitude"] = f"{float(alt):.0f}"

    url = f"http://{TRACCAR_HOST}:{TRACCAR_PORT}/"
    r = requests.get(url, params=params, timeout=HTTP_TIMEOUT_SEC)
    return r.status_code, r.text[:120]

def parse_csv_v1(line: str):
    # v1,<device_id>,<fix>,<lat>,<lon>,<speed>,<alt>,<vsat>,<acc>,<ts_iso_utc>
    parts = line.split(",")
    if len(parts) != 10:
        raise ValueError(f"expected 10 fields, got {len(parts)}")

    version = parts[0]
    if version != "v1":
        raise ValueError(f"unsupported version {version}")

    device_id = parts[1].strip()
    fix = int(parts[2])
    lat = float(parts[3])
    lon = float(parts[4])
    speed = float(parts[5])
    alt = float(parts[6])
    vsat = int(parts[7])
    acc = float(parts[8])
    ts = parts[9].strip()

    return {
        "device_id": device_id,
        "fix": fix,
        "lat": lat,
        "lon": lon,
        "speed": speed,
        "alt": alt,
        "vsat": vsat,
        "acc": acc,
        "ts": ts,
    }

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        logging.info("MQTT connected")
        client.subscribe(MQTT_TOPIC)
        logging.info("Subscribed to %s", MQTT_TOPIC)
    else:
        logging.error("MQTT connect failed rc=%s", rc)

def on_message(client, userdata, msg):
    global _last_sent_ts, _last_lat, _last_lon

    raw = msg.payload.decode("utf-8", errors="replace").strip()
    if not raw:
        return

    try:
        data = parse_csv_v1(raw)
    except Exception as e:
        logging.warning("Bad CSV payload: %r (%s)", raw[:200], e)
        return

    # Guardrail fix mínimo (igual que tu lógica actual)
    fix = int(data.get("fix", 0) or 0)
    if fix < 2:
        logging.info("Skip: bad fix=%s ts=%s", fix, data.get("ts"))
        return

    lat = data["lat"]
    lon = data["lon"]

    ok, reason = should_send(lat, lon)
    if not ok:
        logging.info("Skip: %s", reason)
        return

    device_id = data["device_id"] or TRACCAR_DEVICE_ID_FALLBACK
    if not device_id:
        logging.warning("Skip: missing device_id (CSV and env)")
        return

    try:
        code, preview = send_osmand(device_id, lat, lon, data.get("speed"), data.get("alt"))
        if code == 200:
            _last_sent_ts = time.time()
            _last_lat = lat
            _last_lon = lon
            logging.info("TRACCAR OK id=%s lat=%.5f lon=%.5f fix=%s vsat=%s acc=%.2f",
                         device_id, lat, lon, fix, data.get("vsat"), data.get("acc"))
        else:
            logging.warning("TRACCAR HTTP %s body=%s", code, preview)
    except Exception as e:
        logging.warning("TRACCAR send failed: %s", e)


def main():
    client = mqtt.Client()
    if MQTT_USER:
        client.username_pw_set(MQTT_USER, MQTT_PASS)

    client.on_connect = on_connect
    client.on_message = on_message

    logging.info("Connecting MQTT %s:%s topic=%s", MQTT_HOST, MQTT_PORT, MQTT_TOPIC)
    client.connect(MQTT_HOST, MQTT_PORT, keepalive=30)
    client.loop_forever()

if __name__ == "__main__":
    main()
