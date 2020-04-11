﻿
// Upgrade NOTE: replaced 'mul(UNITY_MATRIX_MVP,*)' with 'UnityObjectToClipPos(*)'
// Copyright (c) <2015> <Playdead>
// This file is subject to the MIT License as seen in the root of this folder structure (LICENSE.TXT)
// AUTHOR: Lasse Jon Fuglsang Pedersen <lasse@playdead.com>

Shader "Playdead/Post/TemporalReprojection"
{
	Properties
	{
		_MainTex ("Base (RGB)", 2D) = "white" {}
	}

	CGINCLUDE
	//--- program begin
	
	#pragma only_renderers ps4 xboxone d3d11 d3d9 xbox360 opengl glcore gles3 metal vulkan
	#pragma target 3.0

	#pragma multi_compile CAMERA_PERSPECTIVE CAMERA_ORTHOGRAPHIC
	//#pragma multi_compile MINMAX_3X3 MINMAX_3X3_ROUNDED MINMAX_4TAP_VARYING
	//#pragma multi_compile __ UNJITTER_COLORSAMPLES
	//#pragma multi_compile __ UNJITTER_NEIGHBORHOOD
	//#pragma multi_compile __ UNJITTER_REPROJECTION
	//#pragma multi_compile __ USE_CHROMA_COLORSPACE
	//#pragma multi_compile __ USE_CLIPPING
	//#pragma multi_compile __ USE_DILATION
	#pragma multi_compile __ USE_MOTION_BLUR
	#pragma multi_compile __ USE_MOTION_BLUR_NEIGHBORMAX
	//#pragma multi_compile __ USE_APPROXIMATE_CLIPPING

	#define USE_DILATION 1
	#define MINMAX_3X3_ROUNDED 1
	#define UNJITTER_COLORSAMPLES 1
	#define USE_CHROMA_COLORSPACE 1
	#define USE_CLIPPING 1
	//#define APPROXIMATE_LUMINANCE_AS_GREEN 1
	#define USE_HIGHER_ORDER_TEXTURE_FILTERING 1

	//TODO: presets
	// best perf: 5 tap nearest, RGB, clamping, green_is_luminance

	#include "UnityCG.cginc"
	#include "IncDepth.cginc"
	#include "IncNoise.cginc"
	#include "IncColor.cginc"

#if SHADER_API_MOBILE
	static const float FLT_EPS = 0.0001f;
#else
	static const float FLT_EPS = 0.00000001f;
#endif

	uniform float4 _JitterUV;// frustum jitter uv deltas, where xy = current frame, zw = previous

	uniform sampler2D _MainTex;
	uniform float4 _MainTex_TexelSize;

	uniform sampler2D_half _VelocityBuffer;
	uniform sampler2D _VelocityNeighborMax;

	uniform sampler2D _PrevTex;
	uniform float4 _PrevTex_TexelSize;

	uniform float _FeedbackMin;
	uniform float _FeedbackMax;
	uniform float _MotionScale;

	struct v2f
	{
		float4 cs_pos : SV_POSITION;
		float2 ss_txc : TEXCOORD0;
	};

	v2f vert(appdata_img IN)
	{
		v2f OUT;

	#if UNITY_VERSION < 540
		OUT.cs_pos = UnityObjectToClipPos(IN.vertex);
	#else
		OUT.cs_pos = UnityObjectToClipPos(IN.vertex);
	#endif
	#if UNITY_SINGLE_PASS_STEREO
		OUT.ss_txc = UnityStereoTransformScreenSpaceTex(IN.texcoord.xy);
	#else
		OUT.ss_txc = IN.texcoord.xy;
	#endif

		return OUT;
	}

	float4 to_working_colorspace( float4 c )
	{
		#if USE_CHROMA_COLORSPACE
			return float4( RGB_YCbCr(c.rgb), c.a );
			//return float4( RGB_YCoCg(c.rgb), c.a );
		#else
			return c;
		#endif
	}
	float4 from_working_colorspace( float4 c )
	{
		#if USE_CHROMA_COLORSPACE
			return float4( YCbCr_RGB(c.rgb), c.a );
			//return float4( YCoCg_RGB(c.rgb), c.a );
		#else
			return c;
		#endif
	}

	float4 clip_aabb(float3 aabb_min, float3 aabb_max, float4 p, float4 q)
	{
	#if USE_APPROXIMATE_CLIPPING
		// note: only clips towards aabb center (but fast!)
		float3 p_clip = 0.5 * (aabb_max + aabb_min);
		float3 e_clip = 0.5 * (aabb_max - aabb_min) + FLT_EPS;

		float4 v_clip = q - float4(p_clip, p.w);
		float3 v_unit = v_clip.xyz / e_clip;
		float3 a_unit = abs(v_unit);
		float ma_unit = max(a_unit.x, max(a_unit.y, a_unit.z));

		if (ma_unit > 1.0)
			return float4(p_clip, p.w) + v_clip / ma_unit;
		else
			return q;// point inside aabb
	#else
		float4 r = q - p;
		float3 rmax = aabb_max - p.xyz;
		float3 rmin = aabb_min - p.xyz;

		const float eps = FLT_EPS;
		if (r.x > rmax.x + eps) r *= (rmax.x / r.x);
		if (r.y > rmax.y + eps) r *= (rmax.y / r.y);
		if (r.z > rmax.z + eps) r *= (rmax.z / r.z);

		if (r.x < rmin.x - eps) r *= (rmin.x / r.x);
		if (r.y < rmin.y - eps) r *= (rmin.y / r.y);
		if (r.z < rmin.z - eps) r *= (rmin.z / r.z);

		return p + r;
	#endif
	}

	float2 sample_velocity_dilated(sampler2D tex, float2 uv, int support)
	{
		float2 du = float2(_MainTex_TexelSize.x, 0.0);
		float2 dv = float2(0.0, _MainTex_TexelSize.y);
		float2 mv = 0.0;
		float rmv = 0.0;

		int end = support + 1;
		for (int i = -support; i != end; i++)
		{
			for (int j = -support; j != end; j++)
			{
				float2 v = tex2D(tex, uv + i * dv + j * du).xy;
				float rv = dot(v, v);
				if (rv > rmv)
				{
					mv = v;
					rmv = rv;
				}
			}
		}

		return mv;
	}

	float4 sample_color_motion(sampler2D tex, float2 uv, float2 ss_vel)
	{
		const float2 v = 0.5 * ss_vel;
		const int taps = 3;// on either side!

		float srand = PDsrand(uv + _SinTime.xx);
		float2 vtap = v / taps;
		float2 pos0 = uv + vtap * (0.5 * srand);
		float4 accu = 0.0;
		float wsum = 0.0;

		[unroll]
		for (int i = -taps; i <= taps; i++)
		{
			float w = 1.0;// box
			//float w = taps - abs(i) + 1;// triangle
			//float w = 1.0 / (1 + abs(i));// pointy triangle
			accu += w * to_working_colorspace(tex2D(tex, pos0 + i * vtap));
			wsum += w;
		}

		return accu / wsum;
	}

	float4 temporal_reprojection(float2 ss_txc, float2 ss_vel, float vs_dist)
	{
		// read texels
		#if UNJITTER_COLORSAMPLES
		float2 cuv = ss_txc - _JitterUV.xy;
		#else
		float2 cuv = ss_txc
		#endif

		// read texels
		#if USE_HIGHER_ORDER_TEXTURE_FILTERING
		half4 texel0 = tex2D(_MainTex, cuv); //sample_cubic(_MainTex, cuv, _MainTex_TexelSize.zw);
		half4 texel1 = sample_catmull_rom(_PrevTex, ss_txc - ss_vel, _PrevTex_TexelSize.zw);
		#else
		half4 texel0 = tex2D(_MainTex, cuv);
		half4 texel1 = tex2D(_PrevTex, ss_txc - ss_vel);
		#endif
		texel0 = to_working_colorspace( texel0 );
		texel1 = to_working_colorspace( texel1 );

		// calc min-max of current neighbourhood
	#if UNJITTER_NEIGHBORHOOD
		float2 uv = ss_txc - _JitterUV.xy;
	#else
		float2 uv = ss_txc;
	#endif

	#if MINMAX_3X3 || MINMAX_3X3_ROUNDED

		float2 du = float2(_MainTex_TexelSize.x, 0.0);
		float2 dv = float2(0.0, _MainTex_TexelSize.y);

		float4 ctl = to_working_colorspace( tex2D(_MainTex, uv - dv - du) );
		float4 ctc = to_working_colorspace( tex2D(_MainTex, uv - dv) );
		float4 ctr = to_working_colorspace( tex2D(_MainTex, uv - dv + du) );
		float4 cml = to_working_colorspace( tex2D(_MainTex, uv - du) );
		float4 cmc = to_working_colorspace( tex2D(_MainTex, uv) );
		float4 cmr = to_working_colorspace( tex2D(_MainTex, uv + du) );
		float4 cbl = to_working_colorspace( tex2D(_MainTex, uv + dv - du) );
		float4 cbc = to_working_colorspace( tex2D(_MainTex, uv + dv) );
		float4 cbr = to_working_colorspace( tex2D(_MainTex, uv + dv + du) );

		float4 cmin5 = min(ctc, min(cml, min(cmc, min(cmr, cbc))));
		float4 cmax5 = max(ctc, max(cml, max(cmc, max(cmr, cbc))));
		float4 csum5 = ctc + cml + cmc + cmr + cbc;
		
		float4 cmin = min(cmin5, min(ctl, min(ctr, min(cbl, cbr))));
		float4 cmax = max(cmax5, max(ctl, max(ctr, max(cbl, cbr))));

		#if MINMAX_3X3_ROUNDED || USE_CHROMA_COLORSPACE || USE_CLIPPING
			float4 cavg = (csum5 + ctl + ctr + cbl + cbr) / 9.0;
		#endif

		#if MINMAX_3X3_ROUNDED
			float4 cavg5 = csum5 * 0.1;
			cmin = 0.5 * (cmin + cmin5);
			cmax = 0.5 * (cmax + cmax5);
			cavg = 0.5 * cavg + cavg5;
		#endif

	#elif MINMAX_4TAP_VARYING// this is the method used in v2 (PDTemporalReprojection2)

		const float _SubpixelThreshold = 0.5;
		const float _GatherBase = 0.5;
		const float _GatherSubpixelMotion = 0.1666;

		float2 texel_vel = ss_vel / _MainTex_TexelSize.xy;
		float texel_vel_mag = length(texel_vel) * vs_dist;
		float k_subpixel_motion = saturate(_SubpixelThreshold / (FLT_EPS + texel_vel_mag));
		float k_min_max_support = _GatherBase + _GatherSubpixelMotion * k_subpixel_motion;

		float2 ss_offset01 = k_min_max_support * float2(-_MainTex_TexelSize.x, _MainTex_TexelSize.y);
		float2 ss_offset11 = k_min_max_support * float2(_MainTex_TexelSize.x, _MainTex_TexelSize.y);
		float4 c00 = to_working_colorspace( tex2D(_MainTex, uv - ss_offset11) );
		float4 c10 = to_working_colorspace( tex2D(_MainTex, uv - ss_offset01) );
		float4 c01 = to_working_colorspace( tex2D(_MainTex, uv + ss_offset01) );
		float4 c11 = to_working_colorspace( tex2D(_MainTex, uv + ss_offset11) );

		float4 cmin = min(c00, min(c10, min(c01, c11)));
		float4 cmax = max(c00, max(c10, max(c01, c11)));

		#if USE_CHROMA_COLORSPACE || USE_CLIPPING
			float4 cavg = (c00 + c10 + c01 + c11) / 4.0;
		#endif

	#else
		#error "missing keyword MINMAX_..."
	#endif

		//note: this seems to introduce noise
		// shrink chroma min-max
		//#if USE_CHROMA_COLORSPACE
		//float2 chroma_extent = 0.25 * 0.5 * (cmax.r - cmin.r);
		//float2 chroma_center = texel0.gb;
		//cmin.yz = chroma_center - chroma_extent;
		//cmax.yz = chroma_center + chroma_extent;
		//cavg.yz = chroma_center;
		//#endif

		// clamp to neighbourhood of current sample
	#if USE_CLIPPING
		texel1 = clip_aabb(cmin.xyz, cmax.xyz, clamp(cavg, cmin, cmax), texel1);
	#else
		texel1 = clamp(texel1, cmin, cmax);
	#endif

		// feedback weight from unbiased luminance diff (t.lottes)
	#if USE_CHROMA_COLORSPACE
		float lum0 = texel0.r;
		float lum1 = texel1.r;
	#else
		#if APPROXIMATE_LUMINANCE_AS_GREEN
		float lum0 = texel0.g;
		float lum1 = texel1.g;
		#else
		float lum0 = Luminance(texel0.rgb);
		float lum1 = Luminance(texel1.rgb);
		#endif
	#endif
		float unbiased_diff = abs(lum0 - lum1) / max(lum0, max(lum1, 0.2));
		float unbiased_weight = 1.0 - unbiased_diff;
		float unbiased_weight_sqr = unbiased_weight * unbiased_weight;
		float k_feedback = lerp(_FeedbackMin, _FeedbackMax, unbiased_weight_sqr);

		// output
		return lerp(texel0, texel1, k_feedback);
	}

	struct f2rt
	{
		fixed4 buffer : SV_Target0;
		fixed4 screen : SV_Target1;
	};

	f2rt frag(v2f IN)
	{
		f2rt OUT;

	#if UNJITTER_REPROJECTION
		float2 uv = IN.ss_txc - _JitterUV.xy;
	#else
		float2 uv = IN.ss_txc;
	#endif

		//TODO
		//note: RPDF blue-noise
		//half4 rnd = tex2Dlod( _DitherTex, float4( IN.ss_txc * IN.mad.xy + IN.mad.zw, 0, 0) );

	#if USE_DILATION
		//--- 3x3 norm (sucks)
		//float2 ss_vel = sample_velocity_dilated(_VelocityBuffer, uv, 1);
		//float vs_dist = depth_sample_linear(uv);

		//--- 5 tap nearest (decent)
		//float3 c_frag = find_closest_fragment_5tap(uv);
		//float2 ss_vel = tex2D(_VelocityBuffer, c_frag.xy).xy;
		//float vs_dist = depth_resolve_linear(c_frag.z);

		//--- 3x3 nearest (good)
		float3 c_frag = find_closest_fragment_3x3(uv);
		float2 ss_vel = tex2D(_VelocityBuffer, c_frag.xy).xy;
		float vs_dist = depth_resolve_linear(c_frag.z);
	#else
		float2 ss_vel = tex2D(_VelocityBuffer, uv).xy;
		float vs_dist = depth_sample_linear(uv);
	#endif

		// temporal resolve
		float4 color_temporal = temporal_reprojection(IN.ss_txc, ss_vel, vs_dist);

		// prepare outputs
		float4 to_buffer = color_temporal;
		
	#if USE_MOTION_BLUR
		#if USE_MOTION_BLUR_NEIGHBORMAX
			ss_vel = _MotionScale * tex2D(_VelocityNeighborMax, IN.ss_txc).xy;
		#else
			ss_vel = _MotionScale * ss_vel;
		#endif

		float vel_mag = length(ss_vel * _MainTex_TexelSize.zw);
		const float vel_trust_full = 2.0;
		const float vel_trust_none = 15.0;
		const float vel_trust_span = vel_trust_none - vel_trust_full;
		float trust = 1.0 - clamp(vel_mag - vel_trust_full, 0.0, vel_trust_span) / vel_trust_span;

		#if UNJITTER_COLORSAMPLES
			float4 color_motion = sample_color_motion(_MainTex, IN.ss_txc - _JitterUV.xy, ss_vel);
		#else
			float4 color_motion = sample_color_motion(_MainTex, IN.ss_txc, ss_vel);
		#endif

		float4 to_screen = lerp(color_motion, color_temporal, trust);
	#else
		float4 to_screen = color_temporal;
	#endif

		to_buffer = from_working_colorspace( to_buffer );
		to_screen = from_working_colorspace( to_screen );

		//// NOTE: velocity debug
		//to_screen.g += 100.0 * length(ss_vel);
		//to_screen = float4(100.0 * abs(ss_vel), 0.0, 0.0);

		// add noise
		float4 noise4 = PDsrand4(IN.ss_txc + _SinTime.x + 0.6959174) / 510.0;
		OUT.buffer = saturate(to_buffer + noise4);
		OUT.screen = saturate(to_screen + noise4);

		// done
		return OUT;
	}

	//--- program end
	ENDCG

	SubShader
	{
		ZTest Always
		Cull Off
		ZWrite Off
		Fog { Mode off }

		Pass
		{
			CGPROGRAM

			#pragma vertex vert
			#pragma fragment frag

			ENDCG
		}
	}

	Fallback off
}
