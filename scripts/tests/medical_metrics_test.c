#include "common/medical_readback.h"
#include <assert.h>
#include <stdio.h>
#define U PL_VOLUME_UNAVAILABLE
int main(void)
{
    struct medical_readback m;
    uint32_t raw[4],i,last;
    medical_analysis_reset(33333);
    for(i=0;i<200;++i) {
        uint32_t q=i%40,level=q<=20?q:40-q;
        raw[0]=70000000-level*2500000; /* Atria need not peak at ventricular ED. */
        raw[1]=60000000-level*1500000;
        raw[2]=40000000+level*3000000;
        raw[3]=30000000+level*2000000;
        medical_analysis_accept(raw,i+1,31);
    }
    medical_readback_capture(&m);
    printf("ED/ES %u/%u period=%u frames bpm=%u ED_LV=%u ES_LV=%u EF=%u\n",
        m.ed_index,m.es_index,m.period_frames,m.bpm_x100,m.raw[4],m.raw[5],m.ef_x100[0]);
    assert(m.raw[4]==100000000&&m.raw[5]==40000000&&m.ef_x100[0]==6000);
    assert(m.raw[0]<m.raw[1]&&m.ef_x100[1]==5714);
    assert(m.period_frames==40&&m.period_us==1333320&&m.bpm_x100==4500);
    assert(m.frame_index==200);
    medical_analysis_accept(raw,200,31);medical_readback_capture(&m);assert(m.frame_index==200);
    medical_analysis_set_source_us(16667);medical_readback_capture(&m);
    assert(m.period_frames==40&&m.bpm_x100==9000);
    medical_analysis_set_source_us(0);medical_readback_capture(&m);
    assert(m.period_frames==40&&m.period_us==U&&m.bpm_x100==U);
    last=m.epoch;medical_analysis_boundary();medical_analysis_accept(raw,201,31);
    medical_readback_capture(&m);
    assert(m.epoch==last+1&&m.frame_index==201&&m.raw[4]==U&&m.bpm_x100==U);
    raw[2]=0xfffffffeu;medical_analysis_accept(raw,202,31);medical_readback_capture(&m);
    assert(m.current_ml_x100[2]==U);
    /* A discontinuous PL sequence also breaks temporal pairing. */
    medical_analysis_accept(raw,300,31);medical_readback_capture(&m);assert(m.epoch==last+2);
    {
        /* Existing normal-23-4 annotation-derived geometry regression. Values
         * test phase timing; they are not clinical EDV/ESV ground truth. */
        static const uint32_t lv[]={3903900,4386684,4094359,4154442,3646682,2994409,3609847,3548114,2624722,2898669,2764287,2463008,1927210,2116805,2027976,2005907,2876835,3085279,3955658,3925184,4072839,3633487,3226730,3525024,4032469,4730610,3942620,3831015,3878531,3837455,2876992,2452798,2292106,2010541,2261004,2129371,2295090,1946688,2470234,2668704,4032312,3632859,3816721,2962757,4171563,4018568,4914236,4422263,3952123,4242956,3176386,3162327,2998414,2761146,2588594,2314882,2208068,2291949,2268308,2826491,2944929,3644483,4335712,5130299,4950050};
        uint32_t pairs=0,old_ed=U;
        medical_analysis_reset(33333);
        for(i=0;i<sizeof(lv)/sizeof(lv[0]);++i) {
            unsigned c;for(c=0;c<4;++c)raw[c]=lv[i];
            medical_analysis_accept(raw,i+1,31);medical_readback_capture(&m);
            if(m.ed_index!=U&&m.ed_index!=old_ed) {
                old_ed=m.ed_index;
                if(pairs==0)assert(m.ed_index>=19&&m.ed_index<=27&&m.es_index>=31&&m.es_index<=39);
                if(pairs==1)assert(m.ed_index>=41&&m.ed_index<=49&&m.es_index>=54&&m.es_index<=60);
                ++pairs;
            }
        }
        assert(pairs==2);
        puts("PS_REAL_CURVE_OK: annotation-derived noisy volume sequence, two complete contractions, no spurious phase pairs");
    }
    puts("PS_CARDIAC_OK: four-chamber ED/ES, two EFs, 40-frame cycle, source FPS, duplicate read, loop boundary, saturation/gap");
    return 0;
}
