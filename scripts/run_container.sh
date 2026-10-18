#!/usr/bin/env bash
set -euo pipefail

WORKDIR="/workspace"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_DIR="$PROJECT_DIR/environment"

# Git Bash on Windows converts Linux-looking arguments passed to docker.exe.
# Convert host paths explicitly and disable MSYS path rewriting inside this script.
# This does not change the user's Git Bash settings outside this script.
case "$(uname -s)" in
  MINGW*|MSYS*)
    HOST_PROJECT_DIR="$(cygpath -m "$PROJECT_DIR")"
    HOST_ENV_DIR="$(cygpath -m "$ENV_DIR")"
    export MSYS_NO_PATHCONV=1
    ;;
  *)
    HOST_PROJECT_DIR="$PROJECT_DIR"
    HOST_ENV_DIR="$ENV_DIR"
    ;;
esac

REBUILD=false
RESTART=false
FORCE_CPU=false
FORCE_GPU=false

for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=true ;;
    --restart) RESTART=true ;;
    --cpu) FORCE_CPU=true ;;
    --gpu) FORCE_GPU=true ;;
    *) echo "Неизвестный флаг: $arg"; exit 1 ;;
  esac
done

if $FORCE_CPU && $FORCE_GPU; then
  echo "Ошибка: нельзя одновременно указать --cpu и --gpu."
  exit 1
fi

NVIDIA_OK=false
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  NVIDIA_OK=true
fi

if $FORCE_GPU; then
  if ! $NVIDIA_OK; then
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║  Запрошен --gpu, но nvidia-smi недоступен на хосте.       ║"
    echo "║  Нужны драйвер NVIDIA и Container Toolkit:                ║"
    echo "║  https://docs.nvidia.com/datacenter/cloud-native/         ║"
    echo "║  container-toolkit/latest/install-guide.html             ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    exit 1
  fi
  USE_GPU=true
elif $FORCE_CPU; then
  USE_GPU=false
elif $NVIDIA_OK; then
  USE_GPU=true
else
  USE_GPU=false
fi

if $USE_GPU; then
  IMAGE="mujoco-vnc"
  DOCKERFILE="Dockerfile"
  CONTAINER="mujoco-sim"
  echo "==> Режим GPU: образ ${IMAGE}, контейнер ${CONTAINER}"
  echo "==> GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
else
  IMAGE="mujoco-vnc-cpu"
  DOCKERFILE="Dockerfile.cpu"
  CONTAINER="mujoco-sim-cpu"
  echo "==> Режим без GPU (CPU-образ). Все команды python3 / pytest — только внутри контейнера."
  echo "==> Обучение с GPU: Google Colab (train.ipynb) или машина с NVIDIA + ./scripts/run_container.sh --gpu"
fi

container_running() { docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; }
container_exists()  { docker inspect "$CONTAINER" &>/dev/null; }
image_exists()      { docker image inspect "$IMAGE" &>/dev/null; }

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
USER_NAME=$(whoami)

print_connect_info() {
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  VNC готов!"
  echo "════════════════════════════════════════════════════════════"
  echo ""
  echo "  Docker Desktop (macOS / Windows): порты проброшены на хост — откройте:"
  echo "    noVNC:       http://localhost:6080/vnc.html"
  echo "    VNC-клиент:  localhost:5900"
  echo ""
  echo "  Linux без Docker Desktop (или удалённая ВМ с IP):"
  echo "    noVNC:       http://${HOSTNAME}:6080/vnc.html"
  echo "    VNC-клиент:  ${HOSTNAME}:5900"
  echo ""
  echo "  SSH-туннель с ноутбука на ВМ:"
  echo "    ssh -L 6080:localhost:6080 -L 5900:localhost:5900 ${USER_NAME}@${HOSTNAME}"
  echo "    затем http://localhost:6080/vnc.html"
  echo "════════════════════════════════════════════════════════════"
  echo ""
}

build_image() {
  docker build --network host -t "$IMAGE" -f "$HOST_ENV_DIR/$DOCKERFILE" "$HOST_PROJECT_DIR"
}

if $REBUILD; then
  echo "==> Останавливаю контейнер ${CONTAINER}..."
  docker rm -f "$CONTAINER" 2>/dev/null || true
  echo "==> Пересобираю образ..."
  build_image
elif $RESTART; then
  echo "==> Перезапускаю контейнер..."
  docker rm -f "$CONTAINER" 2>/dev/null || true
fi

if ! image_exists; then
  echo "==> Образ не найден, собираю ${IMAGE}..."
  build_image
fi

if container_running; then
  echo "==> Контейнер уже запущен, подключаюсь..."
  print_connect_info
  exec docker exec -it -w "$WORKDIR" "$CONTAINER" bash
fi

if container_exists; then
  echo "==> Запускаю остановленный контейнер..."
  docker start "$CONTAINER"
  sleep 2
  print_connect_info
  exec docker exec -it -w "$WORKDIR" "$CONTAINER" bash
fi

echo "==> Запускаю новый контейнер ${CONTAINER}..."
# On Linux use host networking, as in the original script.
# On macOS / Windows Docker Desktop use published ports.
if [ "$(uname -s)" = "Linux" ]; then
  NETWORK_ARGS=(--network host)
  PORT_ARGS=()
else
  NETWORK_ARGS=()
  PORT_ARGS=(-p 5900:5900 -p 6080:6080)
fi

if $USE_GPU; then
  docker run -d \
    --name "$CONTAINER" \
    --ipc=host \
    "${PORT_ARGS[@]}" \
    "${NETWORK_ARGS[@]}" \
    --gpus all \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    --mount "type=bind,source=${HOST_PROJECT_DIR},target=${WORKDIR}" \
    "$IMAGE"
else
  docker run -d \
    --name "$CONTAINER" \
    --ipc=host \
    "${PORT_ARGS[@]}" \
    "${NETWORK_ARGS[@]}" \
    --mount "type=bind,source=${HOST_PROJECT_DIR},target=${WORKDIR}" \
    "$IMAGE"
fi

sleep 2
print_connect_info
echo "==> Подключаюсь..."
exec docker exec -it -w "$WORKDIR" "$CONTAINER" bash
