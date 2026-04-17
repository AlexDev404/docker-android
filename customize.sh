#!/system/bin/sh

ui_print "================================================"
ui_print "  Docker Chroot SELinux + Mount"
ui_print "================================================"
ui_print ""
ui_print "  SELinux rules:"
ui_print "    allow kernel system_data_file file"
ui_print "      { read write open getattr }"
ui_print "    allow system_data_file system_data_file"
ui_print "      filesystem { associate }"
ui_print ""
ui_print "  Boot mount:"
ui_print "    docker-storage.img -> /var/lib/docker"
ui_print "    context=u:object_r:system_data_file:s0"
ui_print "    shared propagation + chroot self-bind"
ui_print ""
ui_print "  Log: /data/local/tmp/docker-mount.log"
ui_print "================================================"

# Ensure service.sh is executable
set_perm $MODPATH/service.sh 0 0 0755
