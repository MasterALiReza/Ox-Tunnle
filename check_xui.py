import paramiko
import sys
client = paramiko.SSHClient()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
client.connect('45.94.4.78', port=22, username='root', password='TcBWAg2ubt')
stdin, stdout, stderr = client.exec_command('journalctl -u x-ui -n 50 --no-pager')
print(stdout.read().decode('utf-8', errors='replace'))
client.close()
