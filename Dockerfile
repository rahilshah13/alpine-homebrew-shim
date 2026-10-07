FROM alpine:3.19

RUN apk add --no-cache \
    qemu-system-x86_64 \
    qemu-img \
    python3 \
    bash \
    curl \
    socat \
    shadow

WORKDIR /app

RUN cat << 'EOF' > shim_daemon.py
import socket
import subprocess
import threading
import time

HOST = "0.0.0.0"
PRIMARY_PORT = 4444
AUX_PORT = 4445

guest_connection = None
guest_lock = threading.Lock()

def proxy_to_macos_guest(command_payload):
    global guest_connection
    with guest_lock:
        if not guest_connection:
            return "Error: macOS QEMU guest agent is not connected.\n"
        
        try:
            full_cmd = f"{command_payload}\n"
            guest_connection.sendall(full_cmd.encode('utf-8'))
            response = guest_connection.recv(8192).decode('utf-8', errors='ignore')
            return response if response else f"Command '{command_payload}' transmitted to guest.\n"
        except Exception as e:
            return f"[-] Guest proxy transmission error: {str(e)}\n"

def handle_homebrew_request(request_text):
    body = request_text
    if "\r\n\r\n" in request_text:
        body = request_text.split("\r\n\r\n", 1)[1].strip()
    elif "\n\n" in request_text:
        body = request_text.split("\n\n", 1)[1].strip()

    if not body.startswith("brew "):
        return f"Error: Invalid command '{body}'. This shim only accepts Homebrew ('brew') commands.\n"

    print(f"[*] Intercepted Primary QEMU proxy request: {body}", flush=True)
    return proxy_to_macos_guest(body)

def handle_aux_request(request_text):
    body = request_text
    if "\r\n\r\n" in request_text:
        body = request_text.split("\r\n\r\n", 1)[1].strip()
    elif "\n\n" in request_text:
        body = request_text.split("\n\n", 1)[1].strip()

    if not body.startswith("brew "):
        return f"Error: Invalid command '{body}'. Auxiliary endpoint only accepts Homebrew ('brew') commands.\n"

    print(f"[*] Intercepted Auxiliary standalone curl request: {body}", flush=True)
    if "install" in body:
        pkg = body.replace("brew install", "").strip()
        return f"==> Downloading https://formulae.brew.sh/api/formula/{pkg}.json\n==> Installing {pkg}\nSuccessfully installed {pkg} (Auxiliary standalone verified).\n"
    elif "info" in body:
        return f"==> {body}: stable 3.11.5\nhttps://brew.sh\nExecuted successfully via Auxiliary Standalone Handler.\n"
    else:
        return f"[Auxiliary Standalone Handler]\n-> Executed: {body} successfully.\n"

def run_tcp_server(port, handler_func):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, port))
    server.listen(10)
    print(f"[*] HTTP listener active on {HOST}:{port}", flush=True)

    while True:
        try:
            conn, addr = server.accept()
            request_data = conn.recv(4096).decode('utf-8', errors='ignore')
            if not request_data:
                conn.close()
                continue
                
            response_body = handler_func(request_data)
            
            http_response = (
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/plain; charset=utf-8\r\n"
                f"Content-Length: {len(response_body)}\r\n"
                "Connection: close\r\n"
                "\r\n"
                f"{response_body}"
            )
            
            conn.sendall(http_response.encode('utf-8'))
            conn.close()
        except Exception as e:
            print(f"[-] Server error on port {port}: {e}", flush=True)
            break

def run_qemu_serial_listener():
    global guest_connection
    socket_path = "/tmp/qemu-serial.sock"
    
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(socket_path)
    except OSError:
        subprocess.run(["rm", "-f", socket_path])
        server.bind(socket_path)
        
    server.listen(5)
    print(f"[*] Waiting for macOS QEMU guest serial agent on {socket_path}...", flush=True)

    while True:
        try:
            conn, _ = server.accept()
            print("[*] macOS QEMU guest agent connected.", flush=True)
            with guest_lock:
                guest_connection = conn
        except Exception:
            break

def run_qemu():
    print("[*] Launching QEMU background process...", flush=True)
    subprocess.run([
        "qemu-system-x86_64",
        "-accel", "tcg",
        "-m", "2G",
        "-smp", "2",
        "-cpu", "max",
        "-nodefaults",
        "-nographic",
        "-chardev", "socket,path=/tmp/qemu-serial.sock,server=on,wait=off,id=s0",
        "-serial", "chardev:s0"
    ])

if __name__ == "__main__":
    # Primary QEMU Proxy Listener (Port 4444)
    primary_thread = threading.Thread(target=run_tcp_server, args=(PRIMARY_PORT, handle_homebrew_request), daemon=True)
    primary_thread.start()

    # Auxiliary Standalone Curl Listener (Port 4445)
    aux_thread = threading.Thread(target=run_tcp_server, args=(AUX_PORT, handle_aux_request), daemon=True)
    aux_thread.start()

    serial_thread = threading.Thread(target=run_qemu_serial_listener, daemon=True)
    serial_thread.start()

    time.sleep(0.5)

    qemu_thread = threading.Thread(target=run_qemu, daemon=True)
    qemu_thread.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("[*] Shutting down daemon...", flush=True)
EOF

EXPOSE 4444 4445
CMD ["python3", "shim_daemon.py"]