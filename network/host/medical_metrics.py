"""Decode PS-computed medical values; no volume conversion or EF calculation here."""
import re

VOLUME_NAMES = ('EDV_LA', 'ESV_LA', 'EDV_RA', 'ESV_RA',
                'EDV_LV', 'ESV_LV', 'EDV_RV', 'ESV_RV')
EF_NAMES = ('EF_LV', 'EF_RV')
UNAVAILABLE = 0xffffffff


def decode_medical_values(flags, coefficient_nano, volumes, efs):
    if (flags not in range(4) or not 0 <= coefficient_nano <= UNAVAILABLE or
            len(volumes) != 8 or len(efs) != 2 or
            any(not 0 <= value <= UNAVAILABLE for value in volumes) or
            any(value != UNAVAILABLE and not 0 <= value <= 10000 for value in efs)):
        raise ValueError('invalid PS medical snapshot')
    if not flags & 1 and any(value != UNAVAILABLE for value in (*volumes, *efs)):
        raise ValueError('unstable PS medical snapshot contains results')
    if coefficient_nano == 0 and any(value != UNAVAILABLE for value in volumes):
        raise ValueError('PS medical volumes have no physical scale')

    def fixed(value):
        return None if value == UNAVAILABLE else '%d.%02d' % divmod(value, 100)

    return {'medical_volumes_ml': dict(zip(VOLUME_NAMES, map(fixed, volumes))),
            'medical_ef_percent': dict(zip(EF_NAMES, map(fixed, efs))),
            'medical_volume_unit': 'mL', 'medical_scale_assumed': bool(flags & 2),
            'medical_snapshot_stable': bool(flags & 1),
            'medical_volume_coefficient': coefficient_nano / 1e9}


def parse_ps_medical(text):
    values = {name: int(value) for name, value in re.findall(
        r'^\[PS medical\]\s+(\w+)\s*=\s*(\d+)\s*$', text, re.M)}
    if not values:  # Older firmware can still report the original raw indices.
        return {}
    required = tuple(name + '_ML_X100' for name in VOLUME_NAMES) + (
        'EF_LV_X100', 'EF_RV_X100', 'FLAGS', 'COEFFICIENT_NANO')
    if any(name not in values for name in required):
        raise ValueError('incomplete PS medical snapshot; rebuild/flash matching PS')
    return decode_medical_values(values['FLAGS'], values['COEFFICIENT_NANO'],
        [values[name + '_ML_X100'] for name in VOLUME_NAMES],
        [values[name + '_X100'] for name in EF_NAMES])
