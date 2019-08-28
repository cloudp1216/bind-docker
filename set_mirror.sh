#!/bin/bash
#


python -c '
mirror = """
[base]
name=CentOS-$releasever - Base
baseurl=http://10.0.0.11/centos/$releasever/os/$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[updates]
name=CentOS-$releasever - Updates
baseurl=http://10.0.0.11/centos/$releasever/updates/$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[extras]
name=CentOS-$releasever - Extras
baseurl=http://10.0.0.11/centos/$releasever/extras/$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

"""

with open("/etc/yum.repos.d/mirror.repo", "w") as pf:
    pf.write(mirror)


epel = """
[epel]
name=Extra Packages for Enterprise Linux 7 - $basearch
baseurl=http://10.0.0.11/epel/7/$basearch
failovermethod=priority
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7

"""

with open("/etc/yum.repos.d/epel.repo", "w") as pf:
    pf.write(epel)

'


