"""Decode PS-computed medical values; no volume conversion or EF calculation here."""
import re
from collections import deque

VOLUME_NAMES = ('EDV_LA', 'ESV_LA', 'EDV_RA', 'ESV_RA',
                'EDV_LV', 'ESV_LV', 'EDV_RV', 'ESV_RV')
EF_NAMES = ('EF_LV', 'EF_RV')
CHAMBERS = ('LA', 'RA', 'LV', 'RV')
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
    result = decode_medical_values(values['FLAGS'], values['COEFFICIENT_NANO'],
        [values[name + '_ML_X100'] for name in VOLUME_NAMES],
        [values[name + '_X100'] for name in EF_NAMES])
    if 'SEQUENCE' in values:
        names=('SEQUENCE','VOLUME_STATUS','FRAME_INDEX','SOURCE_FRAME_US','PERIOD_FRAMES',
               'PERIOD_US','BPM_X100','ED_INDEX','ES_INDEX','EPOCH')
        if any(name not in values for name in (*names,*(f'VOLUME_{c}_ML_X100' for c in CHAMBERS))):
            raise ValueError('incomplete PS cardiac frame snapshot')
        result.update(decode_cardiac_frame([values[n] for n in names]+
                      [values[f'VOLUME_{c}_ML_X100'] for c in CHAMBERS]))
    return result


def decode_cardiac_frame(words):
    if len(words)!=14 or any(not 0<=v<=UNAVAILABLE for v in words):
        raise ValueError('invalid PS cardiac frame snapshot')
    seq,status,index,source_us,frames,duration,bpm,ed,es,epoch,*volumes=words
    if status>31 or (source_us and not 10000<=source_us<=1000000):
        raise ValueError('invalid PS source timing or volume status')
    return {'medical_frame':{'sequence':seq,'status':status,'index':index,'epoch':epoch,
             'volumes_ml':dict(zip(CHAMBERS,(None if v==UNAVAILABLE else '%d.%02d'%divmod(v,100) for v in volumes)))},
            'medical_cycle':{'source_fps':1000000/source_us if source_us else None,
             'period_frames':None if frames==UNAVAILABLE else frames,
             'period_seconds':None if duration==UNAVAILABLE else duration/1e6,
             'heart_rate_bpm':None if bpm==UNAVAILABLE else '%d.%02d'%divmod(bpm,100),
             'ed_index':None if ed==UNAVAILABLE else ed,'es_index':None if es==UNAVAILABLE else es}}


class MedicalCurveHistory:
    """Observe every TCP result BEFORE either preview queue may drop frames."""
    def __init__(self):
        self.samples=deque(maxlen=50)
        self.last_sequence=None

    def observe(self, readback, source):
        point=readback.get('medical_frame')
        if (readback.get('system_mode')!=1 or not point or not point['index']):
            return
        if point['sequence']!=self.last_sequence:
            self.samples.append({**point,
                'source_index':source.get('source_index',source.get('index')),
                'source_path':source.get('source_path',source.get('path'))})
            self.last_sequence=point['sequence']
        readback['medical_history']=list(self.samples)
