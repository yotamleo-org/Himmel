# 50-Vitals series registry

| metric | scale / unit | meaning | provenance |
|---|---|---|---|
| migraine | 0–3 | headache/migraine severity that day | self-report (vault backfill) |
| skin_flare | 0–3 | atopic-dermatitis flare severity | self-report |
| sleep_hours | hours | hours asleep (sum of non-AWAKE stages within main sleep session) | device export / self-report |
| sleep_in_bed_hours | hours | total time-in-bed within main sleep session | device export (Google Health API) |
| hrv_ms | ms | heart-rate variability | device export |
| daily_hrv_ms | ms | historical daily HRV RMSSD aggregate (Fitbit daily aggregate; live data uses hrv_ms) | device export (Google Health API) |
| rhr_bpm | bpm | resting heart rate | device export |
| daily_rhr_bpm | bpm | historical daily resting heart rate (Fitbit daily aggregate; live data uses rhr_bpm) | device export (Google Health API) |
| spo2_pct | % | oxygen saturation (per-sample mean per day) | device export (Google Health API) |
| daily_spo2_pct | % | daily average oxygen saturation | device export (Google Health API) |
| respiratory_rate | br/min | breathing rate | device export (Google Health API) |
| sleep_temp_c | °C | nightly skin temperature deviation | device export (Google Health API) |
| weight_kg | kg | body weight | device export (Google Health API) |
| height_cm | cm | body height | device export (Google Health API) |
| body_fat_pct | % | body fat percentage | device export (Google Health API) |
| steps | steps | daily step count | device export (Google Health API) |
| distance_km | km | distance traveled | device export (Google Health API) |
| altitude_gain_km | km | elevation gain | device export (Google Health API) |
| active_energy_kcal | kcal | active energy burned | device export (Google Health API) |
| active_minutes | min | total active minutes | device export (Google Health API) |
| active_zone_minutes | min | active zone minutes | device export (Google Health API) |
| sedentary_minutes | min | sedentary time | device export (Google Health API) |
| exercise_minutes | min | structured exercise duration | device export (Google Health API) |
| hydration_ml | ml | water intake | device export (Google Health API) |
| swim_strokes | strokes | swim stroke count | device export (Google Health API) |

Series files: `<metric>.csv` (header `date,value`, ISO dates). Written only via the reviewed luna-vitals
extraction (never auto). LUNA_SERIES_DIR points here.
