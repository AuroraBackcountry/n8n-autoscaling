#!/bin/bash
# =============================================================
# Hetzner n8n Instance Diagnostic Script
# =============================================================

set +e  # Don't exit on non-zero — many diagnostic commands legitimately return non-zero

echo "=============================================="
echo "  Hetzner n8n Diagnostic Report"
echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=============================================="

# --- System Info ---
echo ""
echo ">>> SYSTEM INFO"
echo "Hostname: $(hostname)"
echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
echo "Kernel: $(uname -r)"
echo "Arch: $(uname -m)"
echo "Uptime: $(uptime -p 2>/dev/null || uptime)"

# --- CPU & RAM ---
echo ""
echo ">>> CPU & MEMORY"
echo "CPU: $(nproc) cores — $(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)"
echo ""
free -h 2>/dev/null || echo "free command not available"
echo ""
echo "Load averages: $(cat /proc/loadavg)"

# --- Disk ---
echo ""
echo ">>> DISK USAGE"
df -h / 2>/dev/null
echo ""
df -h /var/lib/docker 2>/dev/null || echo "(Docker dir not separately mounted)"

# --- Docker Info ---
echo ""
echo ">>> DOCKER INFO"
docker --version 2>/dev/null || echo "Docker not found"
docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || echo "Docker Compose not found"
echo ""
echo "Running containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Size}}" 2>/dev/null || echo "Cannot list containers"

# --- n8n Container Resources ---
echo ""
echo ">>> N8N CONTAINER STATS (snapshot)"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" 2>/dev/null || echo "Cannot get stats"

# --- n8n Version & Env ---
echo ""
echo ">>> N8N CONFIGURATION"
# Try to get n8n env vars (redacting secrets)
# Look for the main n8n container (not autoscaler, worker, webhook, or task-runner)
N8N_CONTAINER=$(docker ps --filter "ancestor=n8nio/n8n" --format "{{.Names}}" 2>/dev/null | grep -vE "(autoscaler|worker|webhook|runner)" | head -1)
if [ -z "$N8N_CONTAINER" ]; then
    # Fallback: look for container name ending in -n8n-1 or just -n8n
    N8N_CONTAINER=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -E "[-_]n8n[-_]?[0-9]*$" | head -1)
fi
if [ -z "$N8N_CONTAINER" ]; then
    # Last resort: any n8n container, excluding known non-main ones
    N8N_CONTAINER=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i n8n | grep -vE "(autoscaler|monitor|worker|webhook|runner)" | head -1)
fi
if [ -n "$N8N_CONTAINER" ]; then
    echo "n8n container: $N8N_CONTAINER"
    echo ""
    echo "Key n8n env vars (secrets redacted):"
    docker exec "$N8N_CONTAINER" env 2>/dev/null | grep -iE "^(N8N_|DB_|EXECUTIONS_|QUEUE_|GENERIC_)" | \
        sed -E 's/(PASSWORD|SECRET|KEY|TOKEN|ENCRYPTION)=.*/\1=***REDACTED***/' | sort
else
    echo "Could not find n8n container"
fi

# --- Task Runner Check ---
echo ""
echo ">>> TASK RUNNER STATUS"
if [ -n "$N8N_CONTAINER" ]; then
    docker exec "$N8N_CONTAINER" env 2>/dev/null | grep -iE "RUNNER" || echo "No RUNNER env vars found"
    echo ""
    echo "Task runner processes:"
    docker exec "$N8N_CONTAINER" ps aux 2>/dev/null | grep -i runner || echo "No runner processes found (ps may not be available in container)"
fi
# Check for separate task runner container
RUNNER_CONTAINER=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i runner || true)
if [ -n "$RUNNER_CONTAINER" ]; then
    echo "Separate runner container detected: $RUNNER_CONTAINER"
else
    echo "No separate runner container found"
fi

# --- DNS Resolution ---
echo ""
echo ">>> DNS RESOLUTION TESTS"
echo "Resolver config:"
cat /etc/resolv.conf 2>/dev/null | grep -v "^#"
echo ""
for host in api.slack.com rwdi.com supabase.co api.anthropic.com; do
    echo -n "  $host -> "
    START=$(date +%s%N)
    RESULT=$(dig +short "$host" 2>/dev/null | head -1) || \
    RESULT=$(nslookup "$host" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}') || \
    RESULT=$(getent hosts "$host" 2>/dev/null | awk '{print $1}') || \
    RESULT="FAILED"
    END=$(date +%s%N)
    echo "$RESULT  ($(( (END - START) / 1000000 ))ms)"
done

# --- IPv6 Check ---
echo ""
echo ">>> IPv6 STATUS"
ip -6 addr show scope global 2>/dev/null | head -5 || echo "No global IPv6 addresses"
echo ""
echo "Docker IPv6:"
docker network inspect bridge 2>/dev/null | grep -i ipv6 || echo "Cannot inspect bridge network"

# --- Network Latency Tests ---
echo ""
echo ">>> NETWORK LATENCY (curl timings)"
test_url() {
    local label="$1"
    local url="$2"
    echo ""
    echo "  $label ($url):"
    curl -4 -o /dev/null -s -w "    DNS: %{time_namelookup}s | Connect: %{time_connect}s | TLS: %{time_appconnect}s | TTFB: %{time_starttransfer}s | Total: %{time_total}s\n" \
        --connect-timeout 10 --max-time 30 "$url" 2>/dev/null || echo "    FAILED or timed out"
}

test_url "Slack API" "https://slack.com/api/api.test"
test_url "Supabase" "https://wsiqvmxoprninpoxwmni.supabase.co/rest/v1/"
test_url "Anthropic API" "https://api.anthropic.com"
test_url "RWDI (main site)" "https://www.rwdi.com"

echo ""
echo "  IPv4 vs IPv6 comparison (Slack):"
echo -n "    IPv4: "
curl -4 -o /dev/null -s -w "%{time_total}s" --connect-timeout 10 --max-time 15 "https://slack.com/api/api.test" 2>/dev/null || echo "FAILED"
echo ""
echo -n "    IPv6: "
curl -6 -o /dev/null -s -w "%{time_total}s" --connect-timeout 10 --max-time 15 "https://slack.com/api/api.test" 2>/dev/null || echo "FAILED/not available"
echo ""

# --- RWDI Deep Dive (primary bottleneck) ---
echo ""
echo ">>> RWDI LATENCY DEEP DIVE"
echo "  Running 3 consecutive tests to check consistency:"
for i in 1 2 3; do
    echo ""
    echo "  Attempt $i:"
    curl -4 -o /dev/null -s -w "    DNS: %{time_namelookup}s | Connect: %{time_connect}s | TLS: %{time_appconnect}s | TTFB: %{time_starttransfer}s | Total: %{time_total}s | HTTP: %{http_code}\n" \
        --connect-timeout 15 --max-time 60 "https://www.rwdi.com" 2>/dev/null || echo "    FAILED or timed out"
done
echo ""
echo "  Traceroute to RWDI (first 15 hops):"
traceroute -4 -m 15 -w 2 www.rwdi.com 2>/dev/null || tracepath -4 www.rwdi.com 2>/dev/null | head -20 || echo "  traceroute/tracepath not available"

echo ""
echo "  Host vs Container comparison (RWDI):"
echo -n "    Host:      "
curl -4 -o /dev/null -s -w "Total: %{time_total}s (DNS: %{time_namelookup}s)\n" --connect-timeout 10 --max-time 30 "https://www.rwdi.com" 2>/dev/null || echo "FAILED"
if [ -n "$N8N_CONTAINER" ]; then
    echo -n "    Container: "
    docker exec "$N8N_CONTAINER" curl -4 -o /dev/null -s -w "Total: %{time_total}s (DNS: %{time_namelookup}s)\n" --connect-timeout 10 --max-time 30 "https://www.rwdi.com" 2>/dev/null || echo "FAILED (curl may not be in container)"
fi

# --- Docker Network ---
echo ""
echo ">>> DOCKER NETWORKING"
echo "Networks:"
docker network ls 2>/dev/null
echo ""
echo "n8n container network mode:"
if [ -n "$N8N_CONTAINER" ]; then
    docker inspect "$N8N_CONTAINER" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null
    echo ""
    echo "n8n container DNS:"
    docker exec "$N8N_CONTAINER" cat /etc/resolv.conf 2>/dev/null | grep -v "^#" || echo "Cannot read container DNS"
fi

# --- Postgres ---
echo ""
echo ">>> POSTGRES CONNECTIVITY"
if [ -n "$N8N_CONTAINER" ]; then
    DB_HOST=$(docker exec "$N8N_CONTAINER" env 2>/dev/null | grep -E "^DB_POSTGRESDB_HOST=" | cut -d= -f2)
    if [ -n "$DB_HOST" ]; then
        echo "DB Host: $DB_HOST"
        echo -n "Ping: "
        ping -c 3 -W 2 "$DB_HOST" 2>/dev/null | tail -1 || echo "Cannot ping (may be normal)"
    else
        echo "DB host not found in env"
    fi
fi

# --- Redis Connectivity ---
echo ""
echo ">>> REDIS CONNECTIVITY"
if [ -n "$N8N_CONTAINER" ]; then
    REDIS_HOST=$(docker exec "$N8N_CONTAINER" env 2>/dev/null | grep -iE "^(QUEUE_BULL_REDIS_HOST|N8N_REDIS_HOST|REDIS_HOST)=" | head -1 | cut -d= -f2)
    REDIS_PORT=$(docker exec "$N8N_CONTAINER" env 2>/dev/null | grep -iE "^(QUEUE_BULL_REDIS_PORT|N8N_REDIS_PORT|REDIS_PORT)=" | head -1 | cut -d= -f2)
    REDIS_PORT=${REDIS_PORT:-6379}
    if [ -n "$REDIS_HOST" ]; then
        echo "Redis Host: $REDIS_HOST:$REDIS_PORT"
        # Check if Redis is a container on the same network (exclude monitor)
        REDIS_CONTAINER=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i redis | grep -v monitor | head -1 || true)
        if [ -n "$REDIS_CONTAINER" ]; then
            echo "Redis container: $REDIS_CONTAINER"
            docker exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null || echo "Cannot ping Redis (redis-cli may not be available)"
            echo ""
            echo "Redis info (memory):"
            docker exec "$REDIS_CONTAINER" redis-cli info memory 2>/dev/null | grep -E "used_memory_human|maxmemory_human|mem_fragmentation" || echo "Cannot get Redis memory info"
            echo ""
            echo "Redis key count:"
            docker exec "$REDIS_CONTAINER" redis-cli dbsize 2>/dev/null || echo "Cannot get Redis dbsize"
        else
            echo "No Redis container found — may be external or using a different name"
            echo -n "TCP connect test: "
            timeout 5 bash -c "echo > /dev/tcp/$REDIS_HOST/$REDIS_PORT" 2>/dev/null && echo "OK" || echo "FAILED"
        fi
    else
        echo "No Redis env vars found — Redis may not be configured"
    fi
fi

# --- n8n Webhook URL Reachability ---
echo ""
echo ">>> WEBHOOK ENDPOINT CHECKS"
N8N_WEBHOOK_URL=$(docker exec "$N8N_CONTAINER" env 2>/dev/null | grep -E "^(N8N_WEBHOOK_URL|WEBHOOK_URL)=" | head -1 | cut -d= -f2 || true)
N8N_EDITOR_URL=$(docker exec "$N8N_CONTAINER" env 2>/dev/null | grep -E "^(N8N_EDITOR_BASE_URL|N8N_HOST)=" | head -1 | cut -d= -f2 || true)

if [ -n "$N8N_WEBHOOK_URL" ]; then
    echo "Webhook URL: $N8N_WEBHOOK_URL"
    echo -n "  External reachability: "
    HTTP_CODE=$(curl -4 -o /dev/null -s -w "%{http_code}" --connect-timeout 10 --max-time 15 "${N8N_WEBHOOK_URL}/webhook/health-check-test-404" 2>/dev/null || echo "FAILED")
    echo "$HTTP_CODE (404 = reachable, connection working)"
else
    echo "N8N_WEBHOOK_URL not set"
fi

if [ -n "$N8N_EDITOR_URL" ]; then
    echo "Editor URL: $N8N_EDITOR_URL"
    echo -n "  External reachability: "
    HTTP_CODE=$(curl -4 -o /dev/null -s -w "%{http_code}" --connect-timeout 10 --max-time 15 "${N8N_EDITOR_URL}/healthz" 2>/dev/null || echo "FAILED")
    echo "$HTTP_CODE (200 = healthy)"
fi

# Internal health check from within the container
if [ -n "$N8N_CONTAINER" ]; then
    echo ""
    echo "  Internal health check (from container):"
    echo -n "    "
    docker exec "$N8N_CONTAINER" curl -s --connect-timeout 5 "http://localhost:5678/healthz" 2>/dev/null || echo "FAILED or curl not in container"
    echo ""
fi

# --- n8n Execution Queue / Backlog ---
echo ""
echo ">>> N8N EXECUTION STATUS"
if [ -n "$N8N_CONTAINER" ]; then
    EXEC_MODE=$(docker exec "$N8N_CONTAINER" env 2>/dev/null | grep -E "^EXECUTIONS_MODE=" | cut -d= -f2 || true)
    echo "Execution mode: ${EXEC_MODE:-regular (default)}"
    EXEC_PROCESS=$(docker exec "$N8N_CONTAINER" env 2>/dev/null | grep -E "^EXECUTIONS_PROCESS=" | cut -d= -f2 || true)
    echo "Execution process: ${EXEC_PROCESS:-main (default)}"
    SAVE_DATA=$(docker exec "$N8N_CONTAINER" env 2>/dev/null | grep -iE "^EXECUTIONS_DATA" || true)
    echo "Execution data settings: ${SAVE_DATA:-defaults}"
fi

# --- Recent Docker Logs (errors only) ---
echo ""
echo ">>> RECENT N8N ERRORS (last 50 error lines)"
if [ -n "$N8N_CONTAINER" ]; then
    docker logs "$N8N_CONTAINER" --since 1h 2>&1 | grep -iE "error|warn|fatal|crash|timeout|ECONNREFUSED|ETIMEDOUT" | tail -50 || echo "No errors found in last hour"
else
    echo "No n8n container found"
fi

echo ""
echo "=============================================="
echo "  Diagnostic complete"
echo "=============================================="
