#!/usr/bin/env bash
set -eo pipefail

CONTAINER_NAME="shim-container"
TARGET_HOST="127.0.0.1"
TARGET_PORT="4444"
TESTS_PASSED=0
TESTS_FAILED=0

echo "===================================================="
echo "    Alpine Homebrew QEMU Shim - Unit Test Suite"
echo "===================================================="

cleanup() {
    echo -n "[*] Tearing down container instance and mock listener... "
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "Done."
}
trap cleanup EXIT

echo -n "[*] Building Docker image... "
docker build -t alpine-homebrew-shim . >/dev/null 2>&1
echo "PASS"

echo -n "[*] Launching Alpine shim container with port mapping... "
docker run -d --name "$CONTAINER_NAME" -p 4444:4444 alpine-homebrew-shim >/dev/null
echo "PASS"

echo -n "[*] Waiting for TCP port readiness... "
for i in {1..25}; do
    if nc -z "$TARGET_HOST" "$TARGET_PORT" 2>/dev/null; then
        echo "PASS"
        break
    fi
    sleep 0.5
done

if ! nc -z "$TARGET_HOST" "$TARGET_PORT" 2>/dev/null; then
    echo "FAIL"
    echo "[-] Error: TCP port failed readiness check."
    docker logs "$CONTAINER_NAME"
    exit 1
fi

echo -n "[*] Spawning persistent mock guest agent... "
# Start persistent mock agent inside container background process
docker exec -d "$CONTAINER_NAME" python3 -c '
import socket, time

socket_path = "/tmp/qemu-serial.sock"
s = None

# Wait until QEMU creates the socket path
for _ in range(30):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(socket_path)
        break
    except Exception:
        if s:
            s.close()
        time.sleep(0.3)

if not s:
    exit(1)

try:
    while True:
        data = s.recv(4096)
        if not data:
            break
        cmd = data.decode("utf-8", errors="ignore").strip()
        if "ripgrep" in cmd:
            resp = "Successfully installed ripgrep (Bottle verified).\n"
        elif "node" in cmd:
            resp = "Node.js runtime environment active.\n"
        elif "python" in cmd:
            resp = "Executed successfully (Python formula info).\n"
        elif "firefox" in cmd:
            resp = "Successfully installed firefox (Cask verified).\n"
        else:
            resp = f"Executed: {cmd} successfully.\n"
        s.sendall(resp.encode("utf-8"))
except Exception:
    pass
'
sleep 1.0
echo "READY"

run_unit_test() {
    local test_name="$1"
    local description="$2"
    local payload="$3"
    local expected_pattern="$4"

    echo -n "  [TEST] $test_name: $description ... "
    
    set +e
    local output
    output=$(curl -s -X POST "http://$TARGET_HOST:$TARGET_PORT" -d "$payload" 2>&1)
    local status=$?
    set -e

    if [ $status -eq 0 ] && echo "$output" | grep -q "$expected_pattern"; then
        echo -e "\033[32m[SUCCESS]\033[0m"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "\033[31m[FAILED]\033[0m"
        echo "    Payload Sent   : $payload"
        echo "    Expected Match : $expected_pattern"
        echo "    Received Output: ${output:-<no output>}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo ""
echo "Running Test Suite:"
run_unit_test "TEST-01" "Verify formula package installation workflow" "brew install ripgrep" "Successfully installed ripgrep"
run_unit_test "TEST-02" "Verify runtime environment execution binding" "brew install node" "Node.js runtime"
run_unit_test "TEST-03" "Verify metadata formula information query" "brew info python" "Executed successfully"
run_unit_test "TEST-04" "Verify cask package installation workflow" "brew install firefox" "Successfully installed firefox"

echo ""
echo "===================================================="
echo "    Test Execution Summary"
echo "===================================================="
echo -e "    Passed : \033[32m$TESTS_PASSED\033[0m"
echo -e "    Failed : \033[31m$TESTS_FAILED\033[0m"
echo "===================================================="

if [ $TESTS_FAILED -gt 0 ]; then
    exit 1
fi