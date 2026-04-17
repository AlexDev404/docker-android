# docker-android
Docker for android using `chroot-distro` and `pivot_root`

# Step 0 - Install alpine and pivot_root into it
```powershell
chroot-distro install alpine
./pivot_root.sh
```

# Step 1 - Install docker (v24 matters here)
```powershell
wget https://download.docker.com/linux/static/stable/aarch64/docker-24.0.9.tgz
tar -xzf docker-24.0.9.tgz
mv docker/* /usr/local/bin/
rm -rf docker docker-24.0.9.tgz
```

# Step 2 - Add `crun` and test
```powershell
apk search crun
apk info crun 2>/dev/null | head -5

# If available:
apk add crun
crun --version

# Test it against the same cgroup layout
mkdir -p /tmp/crun-test/rootfs
cd /tmp/crun-test
cp -a /bin /etc /lib /usr rootfs/ 2>/dev/null
crun spec
crun run testctr 2>&1 | head -20
cd -
```

# Step 3 - Start docker and test
```powershell
./start_docker.sh
docker run hello-world
```
