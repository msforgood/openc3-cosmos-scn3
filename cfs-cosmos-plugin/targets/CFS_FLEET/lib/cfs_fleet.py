# This class can be used in your scripts like so:
#   load_utility 'CFS_Fleet/lib/cfs_fleet.py'
#   fleet = CFS_Fleet()
#   fleet.utility()
# For more information see the OpenC3 scripting guide

from openc3.script import *

class CFS_Fleet:
    def utility(self):
        pass
    def get_cfs_fleet_target_name_list(self):
        return <%= cfs_fleet_target_names.inspect %>

    def get_tlm_output_ip(self, target):
        destinations = {
            'CFS-1_BBB': '<%= cfs_bbb_tlm_output_ip %>',
            'CFS-1_QEMU': '<%= cfs_qemu_tlm_output_ip %>',
        }
        return destinations[target]
