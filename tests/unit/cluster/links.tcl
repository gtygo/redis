# Returns a parsed CLUSTER LINKS output of the instance identified
# by the given `id` as a list of dictionaries, with each dictionary
# corresponds to a link.
proc get_cluster_links id {
    set lines [R $id cluster links]
    set links {}
    foreach l $lines {
        if {$l eq {}} continue
        assert_equal [llength $l] 12
        assert_equal [lindex $l 0] "direction"
        set dir [lindex $l 1]
        assert_equal [lindex $l 2] "node"
        set node [lindex $l 3]
        assert_equal [lindex $l 4] "create-time"
        set create_time [lindex $l 5]
        assert_equal [lindex $l 6] "events"
        set events [lindex $l 7]
        assert_equal [lindex $l 8] "send-buffer-allocated"
        set send_buffer_allocated [lindex $l 9]
        assert_equal [lindex $l 10] "send-buffer-used"
        set send_buffer_used [lindex $l 11]
        set link [dict create \
            dir $dir \
            node $node \
            create_time $create_time \
            events $events \
            send_buffer_allocated $send_buffer_allocated \
            send_buffer_used $send_buffer_used \
        ]
        lappend links $link
    }
    return $links
}

proc get_links_with_peer {this_instance_id peer_nodename} {
    set links [get_cluster_links $this_instance_id]
    set links_with_peer {}
    foreach l $links {
        if {[dict get $l node] eq $peer_nodename} {
            lappend links_with_peer $l
        }
    }
    return $links_with_peer
}

# Return the entry in CLUSTER LINKS output by instance identified by `this_instance_id` that
# corresponds to the link established toward a peer identified by `peer_nodename`
proc get_link_to_peer {this_instance_id peer_nodename} {
    set links_with_peer [get_links_with_peer $this_instance_id $peer_nodename]
    foreach l $links_with_peer {
        if {[dict get $l dir] eq "to"} {
            return $l
        }
    }
    return {}
}

# Return the entry in CLUSTER LINKS output by instance identified by `this_instance_id` that
# corresponds to the link accepted from a peer identified by `peer_nodename`
proc get_link_from_peer {this_instance_id peer_nodename} {
    set links_with_peer [get_links_with_peer $this_instance_id $peer_nodename]
    foreach l $links_with_peer {
        if {[dict get $l dir] eq "from"} {
            return $l
        }
    }
    return {}
}

# Reset cluster links to their original state
proc reset_links {id} {
    set limit [lindex [R $id CONFIG get cluster-link-sendbuf-limit] 1]

    # Set a 1 byte limit and wait for cluster cron to run
    # (executes every 100ms) and terminate links
    R $id CONFIG SET cluster-link-sendbuf-limit 1
    after 150

    # Reset limit
    R $id CONFIG SET cluster-link-sendbuf-limit $limit

    # Wait until the cluster links come back up for each node
    wait_for_condition 50 100 {
        [number_of_links $id] == [expr [number_of_peers $id] * 2]
    } else {
        fail "Cluster links did not come back up"
    }
}

proc number_of_peers {id} {
    expr [llength $::servers] - 1
}

proc number_of_links {id} {
    llength [get_cluster_links $id]
}

proc publish_messages {server num_msgs msg_size} {
    for {set i 0} {$i < $num_msgs} {incr i} {
        $server PUBLISH channel [string repeat "x" $msg_size]
    }
}

start_cluster 3 0 {tags {external:skip cluster}} {
    test "Each node has two links with each peer" {
        for {set id 0} {$id < [llength $::servers]} {incr id} {
            # Assert that from point of view of each node, there are two links for
            # each peer. It might take a while for cluster to stabilize so wait up
            # to 5 seconds.
            wait_for_condition 50 100 {
                [number_of_peers $id]*2 == [number_of_links $id]
            } else {
                assert_equal [expr [number_of_peers $id]*2] [number_of_links $id]
            }

            set nodes [get_cluster_nodes $id]
            set links [get_cluster_links $id]

            # For each peer there should be exactly one
            # link "to" it and one link "from" it.
            foreach n $nodes {
                if {[cluster_has_flag $n myself]} continue
                set peer [dict get $n id]
                set to 0
                set from 0
                foreach l $links {
                    if {[dict get $l node] eq $peer} {
                        if {[dict get $l dir] eq "to"} {
                            incr to
                        } elseif {[dict get $l dir] eq "from"} {
                            incr from
                        }
                    }
                }
                assert {$to eq 1}
                assert {$from eq 1}
            }
        }
    }

    set primary1_id 0
    set primary2_id 1

    set primary1 [Rn $primary1_id]
    set primary2 [Rn $primary2_id]

    test "Disconnect link when send buffer limit reached" {
        # On primary1, set timeout to 1 hour so links won't get disconnected due to timeouts
        set oldtimeout [lindex [$primary1 CONFIG get cluster-node-timeout] 1]
        $primary1 CONFIG set cluster-node-timeout [expr 60*60*1000]

        # Get primary1's links with primary2
        set primary2_name [dict get [cluster_get_myself $primary2_id] id]
        set orig_link_p1_to_p2 [get_link_to_peer $primary1_id $primary2_name]
        set orig_link_p1_from_p2 [get_link_from_peer $primary1_id $primary2_name]

        # On primary1, set cluster link send buffer limit to 256KB, which is large enough to not be
        # overflowed by regular gossip messages but also small enough that it doesn't take too much
        # memory to overflow it. If it is set too high, Redis may get OOM killed by kernel before this
        # limit is overflowed in some RAM-limited test environments.
        set oldlimit [lindex [$primary1 CONFIG get cluster-link-sendbuf-limit] 1]
        $primary1 CONFIG set cluster-link-sendbuf-limit [expr 256*1024]
        assert {[CI $primary1_id total_cluster_links_buffer_limit_exceeded] eq 0}

        # To manufacture an ever-growing send buffer from primary1 to primary2,
        # make primary2 unresponsive.
        set primary2_pid [srv [expr -1*$primary2_id] pid]
        exec kill -SIGSTOP $primary2_pid

        # On primary1, send 128KB Pubsub messages in a loop until the send buffer of the link from
        # primary1 to primary2 exceeds buffer limit therefore be dropped.
        # For the send buffer to grow, we need to first exhaust TCP send buffer of primary1 and TCP
        # receive buffer of primary2 first. The sizes of these two buffers vary by OS, but 100 128KB
        # messages should be sufficient.
        set i 0
        wait_for_condition 100 0 {
            [catch {incr i} e] == 0 &&
            [catch {$primary1 publish channel [prepare_value [expr 128*1024]]} e] == 0 &&
            [catch {after 500} e] == 0 &&
            [CI $primary1_id total_cluster_links_buffer_limit_exceeded] >= 1
        } else {
            fail "Cluster link not freed as expected"
        }
        puts -nonewline "$i 128KB messages needed to overflow 256KB buffer limit. "

        # A new link to primary2 should have been recreated
        set new_link_p1_to_p2 [get_link_to_peer $primary1_id $primary2_name]
        assert {[dict get $new_link_p1_to_p2 create_time] > [dict get $orig_link_p1_to_p2 create_time]}

        # Link from primary2 should not be affected
        set same_link_p1_from_p2 [get_link_from_peer $primary1_id $primary2_name]
        assert {[dict get $same_link_p1_from_p2 create_time] eq [dict get $orig_link_p1_from_p2 create_time]}

        # Revive primary2
        exec kill -SIGCONT $primary2_pid

        # Reset configs on primary1 so config changes don't leak out to other tests
        $primary1 CONFIG set cluster-node-timeout $oldtimeout
        $primary1 CONFIG set cluster-link-sendbuf-limit $oldlimit

        reset_links $primary1_id
    }

    test "Link memory increases with publishes" {
        set server_id 0
        set server [Rn $server_id]
        set msg_size 10000
        set num_msgs 10

        # Remove any sendbuf limit
        $primary1 CONFIG set cluster-link-sendbuf-limit 0

        # Publish ~100KB to one of the servers
        $server MULTI
        $server INFO memory
        publish_messages $server $num_msgs $msg_size
        $server INFO memory
        set res [$server EXEC]

        set link_mem_before_pubs [getInfoProperty $res mem_cluster_links]

        # Remove the first half of the response string which contains the
        # first "INFO memory" results and search for the property again
        set res [string range $res [expr [string length $res] / 2] end]
        set link_mem_after_pubs [getInfoProperty $res mem_cluster_links]
        
        # We expect the memory to have increased by more than
        # the culmulative size of the publish messages
        set mem_diff_floor [expr $msg_size * $num_msgs]
        set mem_diff [expr $link_mem_after_pubs - $link_mem_before_pubs]
        assert {$mem_diff > $mem_diff_floor}

        # Reset links to ensure no leftover data for the next test
        reset_links $server_id
    }

    test "Link memory resets after publish messages flush" {
        set server [Rn 0]
        set msg_size 100000
        set num_msgs 10

        set link_mem_before [status $server mem_cluster_links]

        # Publish ~1MB to one of the servers
        $server MULTI
        publish_messages $server $num_msgs $msg_size
        $server EXEC

        # Wait until the cluster link memory has returned to below the pre-publish value.
        # We can't guarantee it returns to the exact same value since gossip messages
        # can cause the values to fluctuate.
        wait_for_condition 1000 500 {
            [status $server mem_cluster_links] <= $link_mem_before
        } else {
            fail "Cluster link memory did not settle back to expected range"
        }
    }
}
