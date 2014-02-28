from collections import namedtuple
from cthulhu.util import memoize


import logging


log = logging.getLogger('cthulhu.types')


CRUSH_RULE_TYPE_REPLICATED = 1
CRUSH_RULE_TYPE_ERASURE = 3


ServiceId = namedtuple('ServiceId', ['fsid', 'service_type', 'service_id'])


class SyncObject(object):
    """
    An object from a Ceph cluster that we are maintaining
    a copy of on the Calamari server.

    We wrap these JSON-serializable objects in a python object to:

    - Decorate them with things like id-to-entry dicts
    - Have a generic way of seeing the version of an object

    """
    def __init__(self, version, data):
        self.version = version
        self.data = data

    @classmethod
    def cmp(cls, a, b):
        """
        Slight bastardization of cmp.  Takes two versions,
        and returns a cmp-like value, except that if versions
        are not sortable we only return 0 or 1.
        """
        # Version is something unique per version (like a hash)
        return 1 if a != b else 0


class VersionedSyncObject(SyncObject):
    @classmethod
    def cmp(cls, a, b):
        # Version is something numeric like an epoch
        return cmp(a, b)


class OsdMap(VersionedSyncObject):
    str = 'osd_map'

    def __init__(self, version, data):
        super(OsdMap, self).__init__(version, data)
        if data is not None:
            self.osds_by_id = dict([(o['osd'], o) for o in data['osds']])
            self.pools_by_id = dict([(p['pool'], p) for p in data['pools']])
            self.osd_tree_node_by_id = dict([(o['id'], o) for o in data['tree']['nodes'] if o['id'] >= 0])
        else:
            self.osds_by_id = {}
            self.pools_by_id = {}
            self.osd_tree_node_by_id = {}

    @memoize
    def get_tree_nodes_by_id(self):
        return dict((n["id"], n) for n in self.data['tree']["nodes"])

    def _get_crush_rule_osds(self, rule):
        nodes_by_id = self.get_tree_nodes_by_id()

        def _gather_leaves(node):
            result = set()
            for child_id in node['children']:
                if child_id >= 0:
                    result.add(child_id)
                else:
                    result |= _gather_leaves(nodes_by_id[child_id])

            return result

        def _gather_osds(root, steps):
            if root['id'] >= 0:
                return set([root['id']])

            osds = set()
            for step in steps:
                if step['op'] == 'choose_firstn':
                    # Choose all children of the current node of type 'type'
                    for child_node in [nodes_by_id[i] for i in root['children']]:
                        if child_node['type'] == step['type']:
                            osds |= _gather_osds(child_node, steps[1:])
                elif step['op'] == 'chooseleaf_firstn':
                    for child_node in [nodes_by_id[i] for i in root['children']]:
                        if child_node['type'] == step['type']:
                            osds |= _gather_leaves(root)
                elif step['op'] == 'emit':
                    break

            return osds

        osds = set()
        for i, step in enumerate(rule['steps']):
            if step['op'] == 'take':
                osds |= _gather_osds(nodes_by_id[step['item']], rule['steps'][i + 1:])
        return osds

    @property
    @memoize
    def osds_by_rule_id(self):
        result = {}
        for rule in self.data['crush']['rules']:
            result[rule['rule_id']] = list(self._get_crush_rule_osds(rule))

        return result

    @property
    @memoize
    def osds_by_pool(self):
        """
        Get the OSDS which may be used in this pool

        :return dict of pool ID to OSD IDs in the pool
        """

        result = {}
        for pool_id, pool in self.pools_by_id.items():
            osds = None
            for rule in [r for r in self.data['crush']['rules'] if r['ruleset'] == pool['crush_ruleset']]:
                if rule['min_size'] <= pool['size'] <= rule['max_size']:
                    osds = self.osds_by_rule_id[rule['rule_id']]

            if osds is None:
                # Fallthrough, the pool size didn't fall within any of the rules in its ruleset, Calamari
                # doesn't understand.  Just report all OSDs instead of failing horribly.
                log.error("Cannot determine OSDS for pool %s" % pool_id)
                osds = self.osds_by_id.keys()

            result[pool_id] = osds

        return result

    @property
    @memoize
    def osd_pools(self):
        """
        A dict of OSD ID to list of pool IDs
        """
        osds = dict([(osd_id, []) for osd_id in self.osds_by_id.keys()])
        for pool_id in self.pools_by_id.keys():
            for in_pool_id in self.osds_by_pool[pool_id]:
                osds[in_pool_id].append(pool_id)

        return osds


class MdsMap(VersionedSyncObject):
    str = 'mds_map'


class MonMap(VersionedSyncObject):
    str = 'mon_map'


class MonStatus(VersionedSyncObject):
    str = 'mon_status'

    def __init__(self, version, data):
        super(MonStatus, self).__init__(version, data)
        if data is not None:
            self.mons_by_rank = dict([(m['rank'], m) for m in data['monmap']['mons']])
        else:
            self.mons_by_rank = {}


class PgBrief(SyncObject):
    str = 'pg_brief'


class Health(SyncObject):
    str = 'health'


class Config(SyncObject):
    str = 'config'


MON = 'mon'
OSD = 'osd'
POOL = 'pool'
CRUSH_RULE = 'crush_rule'
CLUSTER = 'cluster'

# The objects that ClusterMonitor keeps copies of from the mon
SYNC_OBJECT_TYPES = [MdsMap, OsdMap, MonMap, MonStatus, PgBrief, Health, Config]
SYNC_OBJECT_STR_TYPE = dict((t.str, t) for t in SYNC_OBJECT_TYPES)

USER_REQUEST_COMPLETE = 'complete'
USER_REQUEST_SUBMITTED = 'submitted'

# List of allowable things to send as ceph commands to OSDs
OSD_IMPLEMENTED_COMMANDS = ['scrub', 'deep_scrub', 'repair']
