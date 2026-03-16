[meta]
name = counter-test
version = 2.0.0
port = 8833
dialogue = Feature test
storage_type = counter-test
health = true
log = logs/counter.log

[dirs]
logs

[install]
for i in $(seq 1 10); do
  printf '%d\n' "$i"
  sleep 0.2
done
printf 'Install done.\n'

[start]
mkdir -p logs
n=0
while true; do
  n=$(( n + 1 ))
  printf '[%s] tick %d\n' "$(date '+%H:%M:%S')" "$n" | tee -a logs/counter.log
  sleep 1
done

[jobs]
[@action]
name = Reset log
cmd = printf '' > logs/counter.log && printf 'Log cleared.\n'

[@action]
name = Show log tail
cmd = tail -20 logs/counter.log

[@cron]
name = ping
schedule = 10s
autostart = true
log = logs/counter.log
cmd =
  printf "[cron] ping at %s\n" $(date +%H:%M:%S)

[@cron]
name = minutely
schedule = 1m
log = logs/counter.log
cmd =
  printf "[cron] 1min heartbeat\n"
