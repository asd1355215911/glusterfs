#!/bin/bash

# Copyright 2015 Red Hat Inc.  All Rights Reserved
#
# Pacemaker+Corosync High Availability for NFS-Ganesha
#
# setup, teardown, add, delete, refresh-config, and status
#
# Each participating node in the cluster is assigned a virtual IP (VIP)
# which fails over to another node when its associated ganesha.nfsd dies
# for any reason. After the VIP is moved to another node all the
# ganesha.nfsds are send a signal using DBUS to put them into NFS GRACE.
#
# There are six resource agent types used: ganesha_mon, ganesha_grace,
# ganesha_nfsd, IPaddr, and Dummy. ganesha_mon is used to monitor the
# ganesha.nfsd. ganesha_grace is used to send the DBUS signal to put
# the remaining ganesha.nfsds into grace. ganesha_nfsd is used to start
# and stop the ganesha.nfsd during setup and teardown. IPaddr manages
# the VIP. A Dummy resource named $hostname-trigger_ip-1 is used to
# ensure that the NFS GRACE DBUS signal is sent after the VIP moves to
# the new host.

HA_NUM_SERVERS=0
HA_SERVERS=""
HA_CONFDIR=""
HA_VOL_NAME="gluster_shared_storage"
HA_VOL_MNT="/var/run/gluster/shared_storage"
SERVICE_MAN="DISTRO_NOT_FOUND"
CONF=$(cat /etc/sysconfig/ganesha | grep "CONFFILE" | cut -f 2 -d "=")

RHEL6_PCS_CNAME_OPTION="--name"

determine_service_manager () {

        if [ -e "/usr/bin/systemctl" ];
        then
                SERVICE_MAN="/usr/bin/systemctl"
        elif [ -e "/sbin/invoke-rc.d" ];
        then
                SERVICE_MAN="/sbin/invoke-rc.d"
        elif [ -e "/sbin/service" ];
        then
                SERVICE_MAN="/sbin/service"
        fi
        if [ "$SERVICE_MAN" == "DISTRO_NOT_FOUND" ]
        then
                echo "Service manager not recognized, exiting"
                exit 1
        fi
}

manage_service ()
{
        if [ "$SERVICE_MAN" == "/usr/sbin/systemctl" ]
        then
                $SERVICE_MAN  $1 nfs-ganesha
        else
                $SERVICE_MAN nfs-ganesha $1
        fi
}

check_cluster_exists()
{
    local name=${1}
    local cluster_name=""

    if [ -e /var/run/corosync.pid ]; then
        cluster_name=$(pcs status | grep "Cluster name:" | cut -d ' ' -f 3)
        if [ ${cluster_name} -a ${cluster_name} = ${name} ]; then
            logger "$name already exists, exiting"
            exit 0
        fi
    fi
}


determine_servers()
{
    local cmd=${1}
    local num_servers=0
    local tmp_ifs=${IFS}
    local ha_servers=""

    if [[ "X${cmd}X" != "XsetupX" ]]; then
        ha_servers=$(pcs status | grep "Online:" | grep -o '\[.*\]' | sed -e 's/\[//' | sed -e 's/\]//')
        IFS=$' '
        for server in ${ha_servers} ; do
            num_servers=$(expr ${num_servers} + 1)
        done
        IFS=${tmp_ifs}
        HA_NUM_SERVERS=${num_servers}
        HA_SERVERS="${ha_servers}"
    else
        IFS=$','
        for server in ${HA_CLUSTER_NODES} ; do
            num_servers=$(expr ${num_servers} + 1)
        done
        IFS=${tmp_ifs}
        HA_NUM_SERVERS=${num_servers}
        HA_SERVERS="${HA_CLUSTER_NODES//,/ }"
    fi
}


setup_cluster()
{
    local name=${1}
    local num_servers=${2}
    local servers=${3}
    local unclean=""

    logger "setting up cluster ${name} with the following ${servers}"

    pcs cluster auth ${servers}
# fedora    pcs cluster setup ${name} ${servers}
# rhel6     pcs cluster setup --name ${name} ${servers}
    pcs cluster setup ${RHEL6_PCS_CNAME_OPTION} ${name} ${servers}
    if [ $? -ne 0 ]; then
        logger "pcs cluster setup ${RHEL6_PCS_CNAME_OPTION} ${name} ${servers} failed"
        exit 1;
    fi
    pcs cluster start --all
    if [ $? -ne 0 ]; then
        logger "pcs cluster start failed"
        exit 1;
    fi

    sleep 3
    unclean=$(pcs status | grep -u "UNCLEAN")
    while [[ "${unclean}X" = "UNCLEANX" ]]; do
         sleep 1
         unclean=$(pcs status | grep -u "UNCLEAN")
    done
    sleep 1

    if [ ${num_servers} -lt 3 ]; then
        pcs property set no-quorum-policy=ignore
        if [ $? -ne 0 ]; then
            logger "warning: pcs property set no-quorum-policy=ignore failed"
        fi
    fi
    pcs property set stonith-enabled=false
    if [ $? -ne 0 ]; then
        logger "warning: pcs property set stonith-enabled=false failed"
    fi
}


setup_finalize()
{
    local cibfile=${1}
    local stopped=""

    stopped=$(pcs status | grep -u "Stopped")
    while [[ "${stopped}X" = "StoppedX" ]]; do
         sleep 1
         stopped=$(pcs status | grep -u "Stopped")
    done

    pcs status | grep dead_ip-1 | sort > /var/run/ganesha/pcs_status

}


setup_copy_config()
{
    local short_host=$(hostname -s)

    if [ -e /var/lib/glusterd/nfs/secret.pem ]; then
        while [[ ${1} ]]; do
            if [ ${short_host} != ${1} ]; then
                scp -oPasswordAuthentication=no -oStrictHostKeyChecking=no -i /var/lib/glusterd/nfs/secret.pem /etc/ganesha/ganesha-ha.conf ${1}:/etc/ganesha/
                if [ $? -ne 0 ]; then
                    logger "warning: scp ganesha-ha.conf to ${1} failed"
                fi
            fi
            shift
        done
    else
        logger "warning: scp ganesha-ha.conf to ${1} failed"
    fi
}

copy_export_config ()
{
        . /etc/ganesha/ganesha.conf
        scp $HA_VOL_SERVER:/etc/ganesha.conf ${1}:/etc/ganesha/
        scp -r $HA_VOL_SERVER:$2/exports/ ${1}:${2}/
}


teardown_cluster()
{
    local name=${1}

    for server in ${HA_SERVERS} ; do
        if [[ ${HA_CLUSTER_NODES} != *${server}* ]]; then
            logger "info: ${server} is not in config, removing"

            pcs cluster stop ${server}
            if [ $? -ne 0 ]; then
                logger "warning: pcs cluster stop ${server} failed"
            fi

            pcs cluster node remove ${server}
            if [ $? -ne 0 ]; then
                logger "warning: pcs cluster node remove ${server} failed"
            fi
        fi
    done

# BZ 1193433 - pcs doesn't reload cluster.conf after modification
# after teardown completes, a subsequent setup will appear to have
# 'remembered' the deleted node. You can work around this by
# issuing another `pcs cluster node remove $node`,
# `crm_node -f -R $server`, or
# `cibadmin --delete --xml-text '<node id="$server"
# uname="$server"/>'

    pcs cluster stop --all
    if [ $? -ne 0 ]; then
        logger "warning pcs cluster stop --all failed"
    fi

    pcs cluster destroy
    if [ $? -ne 0 ]; then
        logger "error pcs cluster destroy failed"
        exit 1
    fi
}


cleanup_ganesha_config ()
{
       rm -rf ${HA_CONFDIR}/exports/*.conf
       rm -rf ${HA_CONFDIR}/.export_added
       rm -rf /etc/cluster/cluster.conf*
       sed -r -i -e '/^%include[[:space:]]+".+\.conf"$/d' $CONF
}


teardown_clean_etccluster()
{
    local short_host=$(hostname -s)

    if [ -e /var/lib/glusterd/nfs/secret.pem ]; then
        while [[ ${1} ]]; do
            if [ ${short_host} != ${1} ]; then
                ssh -oPasswordAuthentication=no -oStrictHostKeyChecking=no -i /var/lib/glusterd/nfs/secret.pem ${1} rm -f /etc/cluster/cluster.*
                if [ $? -ne 0 ]; then
                    logger "warning: ssh ${1} rm -f /etc/cluster/cluster.* failed"
                fi
            fi
            shift
        done
    else
        logger "warning: ssh ${1} rm -f /etc/cluster/cluster.* failed"
    fi
}


do_create_virt_ip_constraints()
{
    local cibfile=${1}; shift
    local primary=${1}; shift
    local weight="1000"

    # first a constraint location rule that says the VIP must be where
    # there's a ganesha.nfsd running
    pcs -f ${cibfile} constraint location ${primary}-cluster_ip-1 rule score=-INFINITY ganesha-active ne 1
    if [ $? -ne 0 ]; then
        logger "warning: pcs constraint location ${primary}-cluster_ip-1 rule score=-INFINITY ganesha-active ne 1 failed"
    fi

    # then a set of constraint location prefers to set the prefered order
    # for where a VIP should move
    while [[ ${1} ]]; do
        pcs -f ${cibfile} constraint location ${primary}-cluster_ip-1 prefers ${1}=${weight}
        if [ $? -ne 0 ]; then
            logger "warning: pcs constraint location ${primary}-cluster_ip-1 prefers ${1}=${weight} failed"
        fi
        weight=$(expr ${weight} + 1000)
        shift
    done
    # and finally set the highest preference for the VIP to its home node
    # default weight when created is/was 100.
    # on Fedora setting appears to be additive, so to get the desired
    # value we adjust the weight
    # weight=$(expr ${weight} - 100)
    pcs -f ${cibfile} constraint location ${primary}-cluster_ip-1 prefers ${primary}=${weight}
    if [ $? -ne 0 ]; then
        logger "warning: pcs constraint location ${primary}-cluster_ip-1 prefers ${primary}=${weight} failed"
    fi
}


wrap_create_virt_ip_constraints()
{
    local cibfile=${1}; shift
    local primary=${1}; shift
    local head=""
    local tail=""

    # build a list of peers, e.g. for a four node cluster, for node1,
    # the result is "node2 node3 node4"; for node2, "node3 node4 node1"
    # and so on.
    while [[ ${1} ]]; do
        if [ "${1}" = "${primary}" ]; then
            shift
            while [[ ${1} ]]; do
                tail=${tail}" "${1}
                shift
            done
        else
            head=${head}" "${1}
        fi
        shift
    done
    do_create_virt_ip_constraints ${cibfile} ${primary} ${tail} ${head}
}


create_virt_ip_constraints()
{
    local cibfile=${1}; shift

    while [[ ${1} ]]; do
        wrap_create_virt_ip_constraints ${cibfile} ${1} ${HA_SERVERS}
        shift
    done
}


setup_create_resources()
{
    local cibfile=$(mktemp -u)

    # mount the HA-state volume and start ganesha.nfsd on all nodes
    pcs resource create nfs_start ganesha_nfsd ha_vol_mnt=${HA_VOL_MNT} --clone
    if [ $? -ne 0 ]; then
        logger "warning: pcs resource create nfs_start ganesha_nfsd ha_vol_mnt=${HA_VOL_MNT} --clone failed"
    fi
    sleep 1
    # cloned resources seem to never have their start() invoked when they
    # are created, but stop() is invoked when they are destroyed. Why???.
    # No matter, we don't want this resource agent hanging around anyway
    pcs resource delete nfs_start-clone
    if [ $? -ne 0 ]; then
        logger "warning: pcs resource delete nfs_start-clone failed"
    fi

    pcs resource create nfs-mon ganesha_mon --clone
    if [ $? -ne 0 ]; then
        logger "warning: pcs resource create nfs-mon ganesha_mon --clone failed"
    fi

    pcs resource create nfs-grace ganesha_grace --clone
    if [ $? -ne 0 ]; then
        logger "warning: pcs resource create nfs-grace ganesha_grace --clone failed"
    fi

    pcs cluster cib ${cibfile}

    while [[ ${1} ]]; do

        # ipaddr=$(grep ^${1} ${HA_CONFIG_FILE} | cut -d = -f 2)
        ipaddrx="VIP_${1//-/_}"

        ipaddr=${!ipaddrx}

        pcs -f ${cibfile} resource create ${1}-cluster_ip-1 ocf:heartbeat:IPaddr ip=${ipaddr} cidr_netmask=32 op monitor interval=15s
        if [ $? -ne 0 ]; then
            logger "warning pcs resource create ${1}-cluster_ip-1 ocf:heartbeat:IPaddr ip=${ipaddr} cidr_netmask=32 op monitor interval=10s failed"
        fi

        pcs -f ${cibfile} resource create ${1}-trigger_ip-1 ocf:heartbeat:Dummy
        if [ $? -ne 0 ]; then
            logger "warning: pcs resource create ${1}-trigger_ip-1 ocf:heartbeat:Dummy failed"
        fi

        pcs -f ${cibfile} constraint colocation add ${1}-cluster_ip-1 with ${1}-trigger_ip-1
        if [ $? -ne 0 ]; then
            logger "warning: pcs constraint colocation add ${1}-cluster_ip-1 with ${1}-trigger_ip-1 failed"
        fi

        pcs -f ${cibfile} constraint order ${1}-trigger_ip-1 then nfs-grace-clone
        if [ $? -ne 0 ]; then
            logger "warning: pcs constraint order ${1}-trigger_ip-1 then nfs-grace-clone failed"
        fi

        pcs -f ${cibfile} constraint order nfs-grace-clone then ${1}-cluster_ip-1
        if [ $? -ne 0 ]; then
            logger "warning: pcs constraint order nfs-grace-clone then ${1}-cluster_ip-1 failed"
        fi

        shift
    done

    create_virt_ip_constraints ${cibfile} ${HA_SERVERS}

    pcs cluster cib-push ${cibfile}
    if [ $? -ne 0 ]; then
        logger "warning pcs cluster cib-push ${cibfile} failed"
    fi
    rm -f ${cibfile}
}


teardown_resources()
{
    # local mntpt=$(grep ha-vol-mnt ${HA_CONFIG_FILE} | cut -d = -f 2)

    # delete -clone resource agents
    # in particular delete the ganesha monitor so we don't try to
    # trigger anything when we shut down ganesha next.
    pcs resource delete nfs-mon-clone
    if [ $? -ne 0 ]; then
        logger "warning: pcs resource delete nfs-mon-clone failed"
    fi

    pcs resource delete nfs-grace-clone
    if [ $? -ne 0 ]; then
        logger "warning: pcs resource delete nfs-grace-clone failed"
    fi

    # unmount the HA-state volume and terminate ganesha.nfsd on all nodes
    pcs resource create nfs_stop ganesha_nfsd ha_vol_mnt=${HA_VOL_MNT} --clone
    if [ $? -ne 0 ]; then
        logger "warning: pcs resource create nfs_stop ganesha_nfsd ha_vol_mnt=${HA_VOL_MNT} --clone failed"
    fi
    sleep 1
    # cloned resources seem to never have their start() invoked when they
    # are created, but stop() is invoked when they are destroyed. Why???.
    pcs resource delete nfs_stop-clone
    if [ $? -ne 0 ]; then
        logger "warning: pcs resource delete nfs_stop-clone failed"
    fi

    while [[ ${1} ]]; do
        pcs resource delete ${1}-cluster_ip-1
        if [ $? -ne 0 ]; then
            logger "warning: pcs resource delete ${1}-cluster_ip-1 failed"
        fi
        pcs resource delete ${1}-trigger_ip-1
        if [ $? -ne 0 ]; then
            logger "warning: pcs resource delete ${1}-trigger_ip-1 failed"
        fi
        pcs resource delete ${1}-dead_ip-1
        if [ $? -ne 0 ]; then
            logger "info: pcs resource delete ${1}-dead_ip-1 failed"
        fi
        shift
    done

}


recreate_resources()
{
    local cibfile=${1}; shift

    while [[ ${1} ]]; do
        ipaddrx="VIP_${1//-/_}"

        ipaddr=${!ipaddrx}

        pcs -f ${cibfile} resource create ${1}-cluster_ip-1 ocf:heartbeat:IPaddr ip=${ipaddr} cidr_netmask=32 op monitor interval=15s
        if [ $? -ne 0 ]; then
            logger "warning pcs resource create ${1}-cluster_ip-1 ocf:heartbeat:IPaddr ip=${ipaddr} cidr_netmask=32 op monitor interval=10s failed"
        fi

        pcs -f ${cibfile} resource create ${1}-trigger_ip-1 ocf:heartbeat:Dummy
        if [ $? -ne 0 ]; then
            logger "warning: pcs resource create ${1}-trigger_ip-1 ocf:heartbeat:Dummy failed"
        fi

        pcs -f ${cibfile} constraint colocation add ${1}-cluster_ip-1 with ${1}-trigger_ip-1
        if [ $? -ne 0 ]; then
            logger "warning: pcs constraint colocation add ${1}-cluster_ip-1 with ${1}-trigger_ip-1 failed"
        fi

        pcs -f ${cibfile} constraint order ${1}-trigger_ip-1 then nfs-grace-clone
        if [ $? -ne 0 ]; then
            logger "warning: pcs constraint order ${1}-trigger_ip-1 then nfs-grace-clone failed"
        fi

        pcs -f ${cibfile} constraint order nfs-grace-clone then ${1}-cluster_ip-1
        if [ $? -ne 0 ]; then
            logger "warning: pcs constraint order nfs-grace-clone then ${1}-cluster_ip-1 failed"
        fi

        shift
    done
}


addnode_recreate_resources()
{
    local cibfile=${1}; shift
    local add_node=${1}; shift
    local add_vip=${1}; shift

    recreate_resources ${cibfile} ${HA_SERVERS}

    pcs -f ${cibfile} resource create ${add_node}-cluster_ip-1 ocf:heartbeat:IPaddr ip=${add_vip} cidr_netmask=32 op monitor interval=15s
    if [ $? -ne 0 ]; then
        logger "warning pcs resource create ${add_node}-cluster_ip-1 ocf:heartbeat:IPaddr ip=${add_vip} cidr_netmask=32 op monitor interval=10s failed"
    fi

    pcs -f ${cibfile} resource create ${add_node}-trigger_ip-1 ocf:heartbeat:Dummy
    if [ $? -ne 0 ]; then
        logger "warning: pcs resource create ${add_node}-trigger_ip-1 ocf:heartbeat:Dummy failed"
    fi

    pcs -f ${cibfile} constraint colocation add ${add_node}-cluster_ip-1 with ${add_node}-trigger_ip-1
    if [ $? -ne 0 ]; then
        logger "warning: pcs constraint colocation add ${add_node}-cluster_ip-1 with ${add_node}-trigger_ip-1 failed"
    fi

    pcs -f ${cibfile} constraint order ${add_node}-trigger_ip-1 then nfs-grace-clone
    if [ $? -ne 0 ]; then
        logger "warning: pcs constraint order ${add_node}-trigger_ip-1 then nfs-grace-clone failed"
    fi

    pcs -f ${cibfile} constraint order nfs-grace-clone then ${add_node}-cluster_ip-1
    if [ $? -ne 0 ]; then
        logger "warning: pcs constraint order nfs-grace-clone then ${add_node}-cluster_ip-1 failed"
    fi
}


clear_resources()
{
    local cibfile=${1}; shift

    while [[ ${1} ]]; do
        pcs -f ${cibfile} resource delete ${1}-cluster_ip-1
        if [ $? -ne 0 ]; then
            logger "warning: pcs -f ${cibfile} resource delete ${1}-cluster_ip-1"
        fi

        pcs -f ${cibfile} resource delete ${1}-trigger_ip-1
        if [ $? -ne 0 ]; then
            logger "warning: pcs -f ${cibfile} resource delete ${1}-trigger_ip-1"
        fi

        shift
    done

    recreate_resources ${cibfile} ${add_node} ${add_vip} ${HA_SERVERS}

}


addnode_create_resources()
{
    local add_node=${1}; shift
    local add_vip=${1}; shift
    local cibfile=$(mktemp -u)

    # mount the HA-state volume and start ganesha.nfsd on the new node
    pcs cluster cib ${cibfile}
    if [ $? -ne 0 ]; then
        logger "warning: pcs cluster cib ${cibfile} failed"
    fi

    pcs -f ${cibfile} resource create nfs_start-${add_node} ganesha_nfsd ha_vol_mnt=${HA_VOL_MNT}
    if [ $? -ne 0 ]; then
        logger "warning: pcs -f ${cibfile} resource create nfs_start-${add_node} ganesha_nfsd ha_vol_mnt=${HA_VOL_MNT} failed"
    fi

    pcs -f ${cibfile} constraint location nfs_start-${add_node} prefers ${newnode}=INFINITY
    if [ $? -ne 0 ]; then
        logger "warning: pcs -f ${cibfile} constraint location nfs_start-${add_node} prefers ${newnode}=INFINITY failed"
    fi

    pcs -f ${cibfile} constraint order nfs_start-${add_node} then nfs-mon-clone
    if [ $? -ne 0 ]; then
        logger "warning: pcs -f ${cibfile} constraint order nfs_start-${add_node} then nfs-mon-clone failed"
    fi

    pcs cluster cib-push ${cibfile}
    if [ $? -ne 0 ]; then
        logger "warning: pcs cluster cib-push ${cibfile} failed"
    fi
    rm -f ${cibfile}

    # start HA on the new node
    pcs cluster start ${add_node}
    if [ $? -ne 0 ]; then
       logger "warning: pcs cluster start ${add_node} failed"
    fi

    pcs resource delete nfs_start-${add_node}
    if [ $? -ne 0 ]; then
        logger "warning: pcs resource delete nfs_start-${add_node} failed"
    fi


    pcs cluster cib ${cibfile}
    if [ $? -ne 0 ]; then
        logger "warning: pcs cluster cib ${cibfile} failed"
    fi

    # delete all the -cluster_ip-1 and -trigger_ip-1 resources,
    # clearing their constraints, then create them again so we can
    # recompute their constraints
    clear_resources ${cibfile} ${HA_SERVERS}
    addnode_recreate_resources ${cibfile} ${add_node} ${add_vip}

    HA_SERVERS="${HA_SERVERS} ${add_node}"
    create_virt_ip_constraints ${cibfile} ${HA_SERVERS}

    pcs cluster cib-push ${cibfile}
    if [ $? -ne 0 ]; then
        logger "warning: pcs cluster cib-push ${cibfile} failed"
    fi
    rm -f ${cibfile}
}


deletenode_delete_resources()
{
    local node=${1}; shift
    local ha_servers=$(echo "${HA_SERVERS}" | sed s/${node}//)
    local cibfile=$(mktemp -u)

    pcs cluster cib ${cibfile}
    if [ $? -ne 0 ]; then
        logger "warning: pcs cluster cib ${cibfile} failed"
    fi

    # delete all the -cluster_ip-1 and -trigger_ip-1 resources,
    # clearing their constraints, then create them again so we can
    # recompute their constraints
    clear_resources ${cibfile} ${HA_SERVERS}
    recreate_resources ${cibfile} ${ha_servers}
    HA_SERVERS="${ha_servers}"

    create_virt_ip_constraints ${cibfile} ${HA_SERVERS}

    pcs cluster cib-push ${cibfile}
    if [ $? -ne 0 ]; then
        logger "warning: pcs cluster cib-push ${cibfile} failed"
    fi
    rm -f ${cibfile}

    pcs cluster cib ${cibfile}
    if [ $? -ne 0 ]; then
        logger "warning: pcs cluster cib ${cibfile} failed"
    fi

    pcs -f ${cibfile} resource create nfs_stop-${node} ganesha_nfsd ha_vol_mnt=${HA_VOL_MNT}
    if [ $? -ne 0 ]; then
        logger "warning: pcs -f ${cibfile} resource create nfs_stop-${node} ganesha_nfsd ha_vol_mnt=${HA_VOL_MNT} failed"
    fi

    pcs -f ${cibfile} constraint location nfs_stop-${node} prefers ${node}=INFINITY
    if [ $? -ne 0 ]; then
        logger "warning: pcs -f ${cibfile} constraint location nfs_stop-${node} prefers ${node}=INFINITY failed"
    fi

    pcs cluster cib-push ${cibfile}
    if [ $? -ne 0 ]; then
        logger "warning: pcs cluster cib-push ${cibfile} failed"
    fi
    rm -f ${cibfile}

    pcs resource delete nfs_stop-${node}
    if [ $? -ne 0 ]; then
        logger "warning: pcs resource delete nfs_stop-${node} failed"
    fi
}


setup_state_volume()
{
    local mnt=${HA_VOL_MNT}
    local longname=""
    local shortname=""
    local dname=""

    longname=$(hostname)
    dname=${longname#$(hostname -s)}

    while [[ ${1} ]]; do
        if [ ! -d ${mnt}/nfs-ganesha/${1}${dname} ]; then
            mkdir ${mnt}/nfs-ganesha/${1}${dname}
        fi
        if [ ! -d ${mnt}/nfs-ganesha/${1}${dname}/nfs ]; then
            mkdir ${mnt}/nfs-ganesha/${1}${dname}/nfs
        fi
        if [ ! -d ${mnt}/nfs-ganesha/${1}${dname}/nfs/ganesha ]; then
            mkdir ${mnt}/nfs-ganesha/${1}${dname}/nfs/ganesha
        fi
        if [ ! -d ${mnt}/nfs-ganesha/${1}${dname}/nfs/statd ]; then
            mkdir ${mnt}/nfs-ganesha/${1}${dname}/nfs/statd
        fi
        touch ${mnt}/nfs-ganesha/${1}${dname}/nfs/state
        if [ ! -d ${mnt}/nfs-ganesha/${1}${dname}/nfs/ganesha/v4recov ]; then
            mkdir ${mnt}/nfs-ganesha/${1}${dname}/nfs/ganesha/v4recov
        fi
        if [ ! -d ${mnt}/nfs-ganesha/${1}${dname}/nfs/ganesha/v4old ]; then
            mkdir ${mnt}/nfs-ganesha/${1}${dname}/nfs/ganesha/v4old
        fi
        if [ ! -d ${mnt}/nfs-ganesha/${1}${dname}/nfs/statd/sm ]; then
            mkdir ${mnt}/nfs-ganesha/${1}${dname}/nfs/statd/sm
        fi
        if [ ! -d ${mnt}/nfs-ganesha/${1}${dname}/nfs/statd/sm.bak ]; then
            mkdir ${mnt}/nfs-ganesha/${1}${dname}/nfs/statd/sm.bak
        fi
        if [ ! -d ${mnt}/nfs-ganesha/${1}${dname}/nfs/statd/state ]; then
            mkdir ${mnt}/nfs-ganesha/${1}${dname}/nfs/statd/state
        fi
        for server in ${HA_SERVERS} ; do
            if [ ${server} != ${1}${dname} ]; then
                ln -s ${mnt}/nfs-ganesha/${server}/nfs/ganesha ${mnt}/nfs-ganesha/${1}${dname}/nfs/ganesha/${server}
                ln -s ${mnt}/nfs-ganesha/${server}/nfs/statd ${mnt}/nfs-ganesha/${1}${dname}/nfs/statd/${server}
            fi
        done
        shift
    done

}


main()
{
    local cmd=${1}; shift
    HA_CONFDIR=${1}; shift
    local node=""
    local vip=""

    . ${HA_CONFDIR}/ganesha-ha.conf

    if [ -e /etc/os-release ]; then
        RHEL6_PCS_CNAME_OPTION=""
    fi

    case "${cmd}" in

    setup | --setup)
        logger "setting up ${HA_NAME}"

        check_cluster_exists ${HA_NAME}

        determine_servers "setup"

        if [ "X${HA_NUM_SERVERS}X" != "X1X" ]; then

            setup_cluster ${HA_NAME} ${HA_NUM_SERVERS} "${HA_SERVERS}"

            setup_create_resources ${HA_SERVERS}

            setup_state_volume ${HA_SERVERS}

            setup_copy_config ${HA_SERVERS}

            setup_finalize
        else

            logger "insufficient servers for HA, aborting"
        fi
        ;;

    teardown | --teardown)
        logger "tearing down ${HA_NAME}"

        determine_servers "teardown"

        teardown_resources ${HA_SERVERS}

        teardown_cluster ${HA_NAME}

        teardown_clean_etccluster ${HA_SERVERS}
        ;;

    cleanup | --cleanup)
        cleanup_ganesha_config ${HA_CONFDIR}
        ;;

    add | --add)
        node=${1}; shift
        vip=${1}; shift

       logger "adding ${node} with ${vip} to ${HA_NAME}"

       determine_servers "add"

        pcs cluster node add ${node}
        if [ $? -ne 0 ]; then
            logger "warning: pcs cluster node add ${node} failed"
        fi

        addnode_create_resources ${node} ${vip}

        setup_state_volume ${node}

        setup_copy_config ${node}

        copy_export_config ${node} ${HA_CONFDIR}

        determine_service_manager

        manage_service "start"
        ;;

    delete | --delete)
        node=${1}; shift

        logger "deleting ${node} from ${HA_NAME}"

        determine_servers "delete"

        deletenode_delete_resources ${node}

        pcs cluster node remove ${node}
        if [ $? -ne 0 ]; then
            logger "warning: pcs cluster node remove ${node} failed"
        fi

        # TODO: delete node's directory in shared state

        teardown_clean_etccluster ${node}

        determine_service_manager

        manage-service "stop"

        cleanup_ganesha_config ${HA_CONFDIR}
        ;;

    status | --status)
        exec pcs status
        ;;

    refresh-config | --refresh-config)
        ;;

    help | --help)
        echo "Usage      : add|delete|status"
        echo "Add-node   : ganesha-ha.sh --add <HA_CONF_DIR>  \
<NODE-IP/HOSTNAME>  <NODE-VIP>"
        echo "Delete-node: ganesha-ha.sh --delete <HA_CONF_DIR>  \
<NODE-IP/HOSTNAME>"
        ;;
      *)
        # setup and teardown are not intended to be used by a
        # casual user
        logger "Usage: ganesha-ha.sh add|delete|status"
        ;;

    esac
}

main $*

