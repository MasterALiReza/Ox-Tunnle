import paramiko
import time
import sys

iran_ip = '91.223.61.233'
eu_ip = '45.94.4.78'

# 1. Start python http server on EU port 9999
eu = paramiko.SSHClient()
eu.set_missing_host_key_policy(paramiko.AutoAddPolicy())
eu.connect(eu_ip, port=22, username='root', password='TcBWAg2ubt')
eu.exec_command('pkill -f "http.server 9999"; nohup python3 -m http.server 9999 > /dev/null 2>&1 &')
time.sleep(2)

# 2. Add port 9999 to Iran config and restart
ir = paramiko.SSHClient()
ir.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ir.connect(iran_ip, port=22, username='root', password='0Yt1kg7^!0Em')
ir.exec_command('echo "PORTS=8081,8082,9999" > /tmp/ports.txt; sed -i "s/^PORTS=.*/PORTS=8081,8082,9999/" /etc/ox_tunnle_manager/profiles/iran1.env')
ir.exec_command('systemctl restart "ox-tunnle@iran1.service"')
time.sleep(5)

# 3. Check logs to see if 9999 is open
stdin, stdout, stderr = ir.exec_command('journalctl -u "ox-tunnle@iran1.service" -n 20 --no-pager')
print("--- IRAN LOGS ---")
print(stdout.read().decode("utf-8", errors="replace"))

# 4. Test curl from Iran
stdin, stdout, stderr = ir.exec_command('curl -v -m 5 http://127.0.0.1:9999')
print("--- CURL OUTPUT ---")
print(stdout.read().decode('utf-8', errors='replace'))
print(stderr.read().decode('utf-8', errors='replace'))

# Revert
ir.exec_command('sed -i "s/^PORTS=.*/PORTS=8081/" /etc/ox_tunnle_manager/profiles/iran1.env')
ir.exec_command('systemctl restart "ox-tunnle@iran1.service"')
eu.exec_command('pkill -f "http.server 9999"')
ir.close()
eu.close()
