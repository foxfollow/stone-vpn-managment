#!/bin/bash
# Примусово прибрати DNS з усіх інтерфейсів і скинути кеш резолвера.
# Інтерфейси (Wi-Fi / iPhone USB) — приклад; зміни під свої за потреби.
sudo networksetup -setdnsservers Wi-Fi empty
sudo networksetup -setdnsservers "iPhone USB" empty

# Flush
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
