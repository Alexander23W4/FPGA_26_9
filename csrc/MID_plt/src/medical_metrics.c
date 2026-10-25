/* Online LV phase detection on source frames, independent of network timing.
 * All four chambers use the SAME LV ED/ES phases. Geometry is a single-view
 * estimate; no ECG or clinical volumetry is reconstructed here. */
#include "common/medical_readback.h"
#include <string.h>
#define U PL_VOLUME_UNAVAILABLE
#define MIN_PHASE 5u
#define MAX_CYCLE 240u
enum {SEEK, FALLING, RISING};
struct phase_sample {uint32_t v[4], id, metric;};
static struct medical_readback result;
static struct phase_sample history[2], high, low, ed;
static uint32_t history_count, state, seeded, rise_seen, confirmations;
static uint32_t previous_es, previous_ed, previous_ed_valid, seen_sequence;
static int initialized;
static uint32_t median3(uint32_t a,uint32_t b,uint32_t c)
{ return a>b ? (b>c?b:(a>c?c:a)) : (a>c?a:(b>c?c:b)); }
static void keep_high(struct phase_sample *target,struct phase_sample s)
{ if(s.metric>target->metric || (s.metric==target->metric&&s.v[2]>=target->v[2]))*target=s; }
static void keep_low(struct phase_sample *target,struct phase_sample s)
{ if(s.metric<target->metric || (s.metric==target->metric&&s.v[2]<=target->v[2]))*target=s; }
static void reset_phase(void)
{
    history_count=state=seeded=rise_seen=confirmations=0;
    previous_ed_valid=0;
}
static void update_rate(void)
{
    result.period_us=result.bpm_x100=U;
    if(result.period_frames!=U && result.source_us) {
        uint64_t duration=(uint64_t)result.period_frames*result.source_us;
        if(duration && duration<U) {
            result.period_us=(uint32_t)duration;
            result.bpm_x100=(uint32_t)((6000000000ull+duration/2)/duration);
        }
    }
}
void medical_analysis_reset(uint32_t source_us)
{
    unsigned i;
    memset(&result,0,sizeof(result));
    for(i=0;i<8;++i) result.raw[i]=result.ml_x100[i]=U;
    for(i=0;i<4;++i) result.current_ml_x100[i]=U;
    result.ef_x100[0]=result.ef_x100[1]=U;
    result.period_frames=result.period_us=result.bpm_x100=U;
    result.ed_index=result.es_index=U;
    result.source_us=source_us;
    result.flags=1u|(PL_VOLUME_SCALE_ASSUMED?2u:0u);
    result.coefficient_nano=PL_VOLUME_ML_COEFF>0.0&&PL_VOLUME_ML_COEFF<4.0?
        (uint32_t)(PL_VOLUME_ML_COEFF*1000000000.0+0.5):0u;
    seen_sequence=0;initialized=1;reset_phase();
}
void medical_analysis_boundary(void)
{
    uint32_t index=result.frame_index,epoch=result.epoch+1,seen=seen_sequence;
    uint32_t source=result.source_us,sequence=result.sequence;
    medical_analysis_reset(source);
    result.frame_index=index;result.epoch=epoch;result.sequence=sequence;seen_sequence=seen;
}
void medical_analysis_set_source_us(uint32_t source_us)
{
    if(!initialized)medical_analysis_reset(source_us);
    result.source_us=source_us;update_rate();
}
static void publish_pair(const struct phase_sample *minimum)
{
    unsigned c;
    for(c=0;c<4;++c) {
        uint32_t a=ed.v[c],b=minimum->v[c];
        result.raw[2*c]=a;result.raw[2*c+1]=b;
        result.ml_x100[2*c]=result.ml_x100[2*c+1]=U;
        if(!a||!b||a>=0xfffffffeu||b>=0xfffffffeu)
            result.raw[2*c]=result.raw[2*c+1]=U;
        else {
            (void)medical_volume_to_ml_x100(a,PL_VOLUME_ML_COEFF,&result.ml_x100[2*c]);
            (void)medical_volume_to_ml_x100(b,PL_VOLUME_ML_COEFF,&result.ml_x100[2*c+1]);
        }
    }
    result.ef_x100[0]=medical_ef_x100(result.raw[4],result.raw[5]);
    result.ef_x100[1]=medical_ef_x100(result.raw[6],result.raw[7]);
    result.ed_index=ed.id;result.es_index=minimum->id;
    if(previous_ed_valid && ed.id-previous_ed>=2*MIN_PHASE && ed.id-previous_ed<=MAX_CYCLE)
        result.period_frames=ed.id-previous_ed;
    previous_ed=ed.id;previous_ed_valid=1;update_rate();
}
static void phase_step(struct phase_sample s)
{
    uint32_t v=s.metric,age=s.id-(state==SEEK?high.id:ed.id);
    uint32_t hh=high.metric>>5,lh=low.metric>>5;
    if(!hh)hh=1;
    if(!lh)lh=1;
    if(!seeded||age>MAX_CYCLE) {
        seeded=1;rise_seen=0;state=SEEK;confirmations=0;high=low=s;return;
    }
    if(state==SEEK&&!rise_seen) {
        if(v<=low.metric) {keep_low(&low,s);high=s;}
        else {
            if(v>=high.metric)keep_high(&high,s);
            if(v-low.metric>=lh && s.id-low.id>=1) {rise_seen=1;low=s;}
        }
    } else if(state==FALLING) {
        if(v>ed.metric||(v==ed.metric&&s.v[2]>ed.v[2])) {ed=high=low=s;confirmations=0;}
        else if(v<=low.metric) {keep_low(&low,s);high=s;confirmations=0;}
        else {
            if(v>=high.metric)keep_high(&high,s);
            if(v-low.metric>=lh) {
                if(++confirmations>=2) {
                    confirmations=0;
                    if(low.id-ed.id>=MIN_PHASE && ed.v[2]>low.v[2]) {
                        publish_pair(&low);previous_es=low.id;state=RISING;low=s;
                    }
                }
            } else confirmations=0;
        }
    } else {
        if(v>=high.metric) {keep_high(&high,s);low=s;confirmations=0;}
        else {
            if(v<=low.metric)keep_low(&low,s);
            if(high.metric-v>=hh) {
                if(++confirmations>=2) {
                    confirmations=0;
                    if(state==SEEK||high.id-previous_es>=MIN_PHASE) {
                        ed=high;state=FALLING;high=s;
                    }
                }
            } else confirmations=0;
        }
    }
}
void medical_analysis_accept(const uint32_t raw[4],uint32_t sequence,uint32_t status)
{
    struct phase_sample s;unsigned c;
    if(!initialized)medical_analysis_reset(0);
    if(seen_sequence && sequence==result.sequence)return;
    if(seen_sequence && sequence-result.sequence!=1)medical_analysis_boundary();
    seen_sequence=1;result.sequence=sequence;result.status=status;
    ++result.frame_index;s.id=result.frame_index;
    for(c=0;c<4;++c) {
        s.v[c]=((status&1u)&&(status&(2u<<c))&&raw[c]&&raw[c]<0xfffffffeu)?raw[c]:U;
        result.current_ml_x100[c]=U;
        (void)medical_volume_to_ml_x100(s.v[c],PL_VOLUME_ML_COEFF,&result.current_ml_x100[c]);
    }
    if(s.v[2]==U) {reset_phase();return;}
    s.metric=s.v[2];
    if(history_count>=2) {
        struct phase_sample center=history[1];
        center.metric=median3(history[0].metric,center.metric,s.metric);
        phase_step(center);
    }
    history[0]=history[1];history[1]=s;
    if(history_count<2)++history_count;
}
void medical_readback_capture(struct medical_readback *out)
{
    if(!initialized)medical_analysis_reset(0);
    *out=result;
}
