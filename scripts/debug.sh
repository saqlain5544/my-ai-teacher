#!/bin/zsh
# Send a debug command to a running app launched with MYAITEACHER_DEBUG=1, then print new log lines.
#   scripts/debug.sh '{"action":"snapshot","path":"/tmp/a.png"}'
LOG=~/Library/Logs/MyAITeacher.log
before=$(wc -l < $LOG 2>/dev/null || echo 0)
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.saqlain.myaiteacher.debug"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)' "$1" 2>/dev/null
sleep ${2:-1.5}
tail -n +$((before + 1)) $LOG
