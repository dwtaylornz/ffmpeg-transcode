[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope='Script')]

$media_path = "Z:\videos\movies\"

$min_video_size = 5000 # min size in MB of video before it will quit 
$min_video_age = 0 # min age of file to process

$ffmpeg_parameters = '-c:a copy -c:v av1_amf -quality balanced -b:v 3M -maxrate 5M -bufsize 5M'
# $ffmpeg_parameters = '-c:a copy -c:v av1_amf -quality balanced -preanalysis 1 -pa_activity_type yuv -pa_scene_change_detection_enable 1 -pa_scene_change_detection_sensitivity high -pa_high_motion_quality_boost_mode auto -b:v 3M -maxrate 5M -bufsize 5M'

$GPU_threads = 2 # how many GPU jobs at same time 

$scan_at_start = 0 # 0 = get previous results and run background scan, 1 = force scan and wait for results, 2 = get results no scan 
$run_health_check = 0 # also run quick health check of videos 
$restart_queue = 720 # mins before re-doing the scan and start going through the queue again
$ffmpeg_logging = "quiet" # "quiet", "panic", "fatal", "error", "warning", "info", "verbose", "debug", "trace"
$ffmpeg_timeout = 6000 # timeout on job (minutes)
$ffmpeg_min_diff = 10 # must be at least this much smalller (percentage)
$ffmpeg_max_diff = 99 # must not save more than this, assuming something has gone wrong (percentage)
$video_codec_skip_list = "av1" # array of video codecs to skip
$move_file = 1 # set to 0 for testing (check .\output directory) 
$log_path = "$PWD" # path to logs and skip files
