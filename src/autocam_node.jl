#!/usr/bin/env julia
using YAML
using RobotOS
using Rotations
using Dates

include("RelaxedIK/relaxedIK.jl")
include("RelaxedIK/GROOVE_RelaxedIK_Julia/relaxedIK_vars.jl")
include("RelaxedIK/Utils_Julia/ros_utils.jl")
include("RelaxedIK/Utils_Julia/autocam_utils.jl")
include("RelaxedIK/Utils_Julia/ema_filter.jl")
include("RelaxedIK/GROOVE_RelaxedIK_Julia/relaxedIK_objective.jl")
include("RelaxedIK/GROOVE_Autocam_Julia/autocam_objective.jl")
include("RelaxedIK/Utils_Julia/solver_output.jl")

@rosimport relaxed_ik.msg : EEPoseGoals, JointAngles
@rosimport geometry_msgs.msg: Point, Quaternion, Pose, Vector3
@rosimport std_msgs.msg: Float64MultiArray, Bool, Float32, Int8
@rosimport visualization_msgs.msg: Marker

rostypegen()
using .relaxed_ik.msg
using .geometry_msgs.msg
using .std_msgs.msg
using .visualization_msgs.msg

eepg = Nothing
function eePoseGoals_cb(data::EEPoseGoals)
    global eepg
    eepg = data
end

search_direction_manual = Nothing
function search_direction_manual_cb(data::Float64MultiArray)
    global search_direction_manual
    search_direction_manual = data.data
end

search_direction_automatic = Nothing
function search_direction_automatic_cb(data::Float64MultiArray)
    global search_direction_automatic
    search_direction_automatic = data.data
end

visual_target_position = Nothing
function visual_target_position_cb(data::Float64MultiArray)
    global visual_target_position
    visual_target_position = data.data
end

camera_mode = 0
function camera_mode_cb(data::Int8Msg)
    global camera_mode
    camera_mode = data.data
end

quit = false
function quit_cb(data::BoolMsg)
    global quit
    quit = data.data
end

reset_solver = false
function reset_cb(data::BoolMsg)
    global reset_solver
    reset_solver = data.data
end

camera_motion_magnitude = 0.2
function camera_motion_magnitude_cb(data::Float32Msg)
    global camera_motion_magnitude
    camera_motion_magnitude = data.data
end

occlusion_score = 0.0
function occlusion_score_cb(data::Float32Msg)
    global occlusion_score
    occlusion_score = data.data
end

goal_dis = 0.6
function goal_dis_cb(data::Float32Msg)
    global goal_dis
    goal_dis = data.data
end

# function loop()
path_to_src = Base.source_dir()
loaded_robot_file = open(path_to_src * "/RelaxedIK/Config/loaded_robot")
loaded_robot = readline(loaded_robot_file)
close(loaded_robot_file)

fp = open(path_to_src * "/RelaxedIK/Config/info_files/" * loaded_robot)
y = YAML.load(fp)
close(fp)

fixed_frame = y["fixed_frame"]

relaxedIK_mode0 = get_autocam1(path_to_src, loaded_robot)
# relaxedIK_mode0 = get_2018_autocam(path_to_src, loaded_robot)
relaxedIK_mode1 = get_autocam_visual_exploration_mode1(path_to_src, loaded_robot)
relaxedIK = relaxedIK_mode0

num_chains = relaxedIK.relaxedIK_vars.robot.num_chains
# num_chains = 1

println("loaded robot: $loaded_robot")

init_node("autocam_node")

Subscriber{EEPoseGoals}("/relaxed_ik/ee_pose_goals", eePoseGoals_cb)
Subscriber{Float64MultiArray}("/autocam/search_direction/manual", search_direction_manual_cb)
Subscriber{Float64MultiArray}("/autocam/search_direction/automatic", search_direction_automatic_cb)
Subscriber{Float64MultiArray}("/autocam/visual_target_position", visual_target_position_cb)
Subscriber{Int8Msg}("/autocam/camera_mode", camera_mode_cb)
Subscriber{BoolMsg}("/relaxed_ik/quit", quit_cb)
Subscriber{BoolMsg}("relaxed_ik/reset", reset_cb)
Subscriber{Float32Msg}("/autocam/motion_magnitude", camera_motion_magnitude_cb)
Subscriber{Float32Msg}("/autocam/occlusion_score", occlusion_score_cb)
Subscriber{Float32Msg}("/autocam/goal_dis", goal_dis_cb)
angles_pub = Publisher("/relaxed_ik/joint_angle_solutions", JointAngles, queue_size = 3)
marker_pub = Publisher("/visualization_marker", Marker, queue_size = 3)
cam_pose_pub = Publisher("/autocam/ee_pose/camera_arm", Pose, queue_size = 3 )
man_pose_pub = Publisher("/autocam/ee_pose/manipulation_arm", Pose, queue_size = 3 )

sleep(0.3)

# d = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
# so = Solver_Output(path_to_src, "relaxed_ik", "jaco7_pair", d)

eepg = EEPoseGoals()
pose = Pose()
pose.position.x = 0.0
pose.position.y = 0.0
pose.position.z = 0.0
pose.orientation.w = 1.0
pose.orientation.x = 0.0
pose.orientation.y = 0.0
pose.orientation.z = 0.0
for i = 1:num_chains
    push!(eepg.ee_poses, pose)
end
empty_eepg = eepg

camera_mode = 0
prev_camera_mode = 0
switch_camera_mode_count = 96.0
search_direction_manual = [0.000000001,0.,0.]
search_direction_automatic = [0.000000001,0.,0.]
visual_target_position = [0.,0.,0.]
goal_dis = 0.6
relaxedIK.relaxedIK_vars.robot.getFrames(relaxedIK.relaxedIK_vars.vars.init_state)
relaxedIK.relaxedIK_vars.additional_vars.previous_camera_location = relaxedIK.relaxedIK_vars.robot.arms[2].out_pts[end]
relaxedIK.relaxedIK_vars.additional_vars.visual_target_position = relaxedIK.relaxedIK_vars.robot.arms[1].out_pts[end]
solve_count = 0
last_time_manual_used = time()

println("ready to get first solution...")
loop_rate = Rate(1000)
while true
    global quit
    if quit == true
        println("quitting")
        quit = false
        return
    end

    global reset_solver
    global eepg
    if reset_solver == true
        println("resetting")
        global relaxedIK
        reset_solver = false
        relaxedIK.relaxedIK_vars.vars.xopt = relaxedIK.relaxedIK_vars.vars.init_state
        relaxedIK.relaxedIK_vars.vars.prev_state = relaxedIK.relaxedIK_vars.vars.init_state
        relaxedIK.relaxedIK_vars.vars.prev_state2 = relaxedIK.relaxedIK_vars.vars.init_state
        relaxedIK.relaxedIK_vars.vars.prev_state3 = relaxedIK.relaxedIK_vars.vars.init_state
        eepg = empty_eepg
    end

    global switch_camera_mode, switch_camera_mode_count, prev_camera_mode
    if ! (prev_camera_mode == camera_mode)
        switch_camera_mode_count = 1.0
        rossleep(0.1)
    end

    if switch_camera_mode_count < 96.0
        switch_camera_mode_count = switch_camera_mode_count + 1.0
    end

    if camera_mode == 0
        # global relaxedIK
        relaxedIK = relaxedIK_mode0
    elseif camera_mode == 1
        # global visual_target_position, relaxedIK
        relaxedIK = relaxedIK_mode1
        relaxedIK.relaxedIK_vars.additional_vars.visual_target_position = visual_target_position
    end
    relaxedIK.relaxedIK_vars.vars.weight_priors[3] = 100.0 - switch_camera_mode_count
    prev_camera_mode = camera_mode

    println(relaxedIK.relaxedIK_vars.vars.weight_priors)

    # have way to combine manual and automatic search direction, add that in here...
    n = LinearAlgebra.norm(search_direction_manual)
    global last_time_manual_used
    if n > 0.001
        last_time_manual_used = time()
    end
    Δt = time() - last_time_manual_used
    relaxedIK.relaxedIK_vars.additional_vars.search_direction = 2.0*search_direction_manual + (1.0/(1.0 + 2.718281828459^-(0.3*Δt - 3.0)))*occlusion_score*search_direction_automatic
    relaxedIK.relaxedIK_vars.additional_vars.distance_to_target = goal_dis

    pose_goals = eepg.ee_poses

    pos_goals = []
    quat_goals = []

    for i = 1:num_chains
        p = pose_goals[i]

        pos_x = p.position.x
        pos_y = p.position.y
        pos_z = p.position.z

        quat_w = p.orientation.w
        quat_x = p.orientation.x
        quat_y = p.orientation.y
        quat_z = p.orientation.z

        push!(pos_goals, [pos_x, pos_y, pos_z])
        push!(quat_goals, Quat(quat_w, quat_x, quat_y, quat_z))
    end

    xopt = solve(relaxedIK, pos_goals, quat_goals)
    # add_line(so, xopt, pos_goals[1], quat_goals[1])
    global solve_count
    if solve_count < 10
        solve(relaxedIK_mode1, pos_goals, quat_goals)
    end
    ja = JointAngles()
    for i = 1:length(xopt)
        push!(ja.angles.data, xopt[i])
    end
    publish(angles_pub, ja)

    # xopt_f = filter_signal(ema_filter, xopt)
    println(xopt)

    relaxedIK.relaxedIK_vars.robot.getFrames(xopt)
    relaxedIK.relaxedIK_vars.additional_vars.previous_camera_location = relaxedIK.relaxedIK_vars.robot.arms[2].out_pts[end]
    # global relaxedIK_mode0, relaxedIK_mode1
    # relaxedIK_mode0.relaxedIK_vars.robot.getFrames(xopt)
    # relaxedIK_mode1.relaxedIK_vars.robot.getFrames(xopt)
    # relaxedIK_mode0.relaxedIK_vars.additional_vars.previous_camera_location = relaxedIK_mode0.relaxedIK_vars.robot.arms[2].out_pts[end]
    # relaxedIK_mode1.relaxedIK_vars.additional_vars.previous_camera_location = relaxedIK_mode1.relaxedIK_vars.robot.arms[2].out_pts[end]

    println(relaxedIK.relaxedIK_vars.vars.objective_closures[end](xopt))
    camera_goal_pt = get_camera_goal_location(xopt, relaxedIK.relaxedIK_vars, 2; Δ=camera_motion_magnitude)
    relaxedIK.relaxedIK_vars.additional_vars.camera_goal_position = camera_goal_pt
    draw_arrow_in_rviz(marker_pub, fixed_frame, relaxedIK.relaxedIK_vars.additional_vars.previous_camera_location, camera_goal_pt, 0.03, 0.03, [0.,1.,0.,1.]; id=1)
    draw_sphere_in_rviz(marker_pub, fixed_frame, [-.2, -0.35, .9], [0.2,0.2,0.2], [0.0, 0.8, 0.9, 0.5]; id=5)
    if camera_mode == 0
        # global relaxedIK_mode1
        xopt_f = filter_signal(relaxedIK_mode1.ema_filter, xopt)
        update_relaxedIK_vars!(relaxedIK_mode1.relaxedIK_vars, xopt_f)
        relaxedIK_mode1.relaxedIK_vars.robot.getFrames(xopt_f)
        relaxedIK_mode1.relaxedIK_vars.additional_vars.previous_camera_location = relaxedIK_mode1.relaxedIK_vars.robot.arms[2].out_pts[end]
        eeMat2 = relaxedIK.relaxedIK_vars.robot.arms[1].out_frames[end]
        draw_arrow_in_rviz(marker_pub, fixed_frame, relaxedIK.relaxedIK_vars.additional_vars.previous_camera_location, relaxedIK.relaxedIK_vars.robot.arms[1].out_pts[end] + 0.11*eeMat2[:,2], 0.03, 0.03, [0.,0.,1.,1.]; id=2)
    elseif camera_mode == 1
        # global relaxedIK_mode0
        xopt_f = filter_signal(relaxedIK_mode0.ema_filter, xopt)
        update_relaxedIK_vars!(relaxedIK_mode0.relaxedIK_vars, xopt_f)
        relaxedIK_mode0.relaxedIK_vars.robot.getFrames(xopt_f)
        relaxedIK_mode0.relaxedIK_vars.additional_vars.previous_camera_location = relaxedIK_mode0.relaxedIK_vars.robot.arms[2].out_pts[end]
        draw_arrow_in_rviz(marker_pub, fixed_frame, relaxedIK.relaxedIK_vars.additional_vars.previous_camera_location, visual_target_position, 0.03, 0.03, [0.,0.,1.,1.]; id=2)
    end
    # draw_sphere_in_rviz(marker_pub, fixed_frame, relaxedIK.relaxedIK_vars.additional_vars.previous_camera_location, [0.1,0.1,0.1], [1.,0.,0.,1.])

    cam_pose = Pose()
    man_pose = Pose()
    cam_ee_pos = relaxedIK.relaxedIK_vars.robot.arms[2].out_pts[end]
    man_ee_pos = relaxedIK.relaxedIK_vars.robot.arms[1].out_pts[end]
    cam_ee_quat = Quat(relaxedIK.relaxedIK_vars.robot.arms[2].out_frames[end])
    man_ee_quat = Quat(relaxedIK.relaxedIK_vars.robot.arms[1].out_frames[end])

    cam_pose.position.x = cam_ee_pos[1]
    cam_pose.position.y = cam_ee_pos[2]
    cam_pose.position.z = cam_ee_pos[3]
    cam_pose.orientation.w =  cam_ee_quat.w
    cam_pose.orientation.x = cam_ee_quat.x
    cam_pose.orientation.y = cam_ee_quat.y
    cam_pose.orientation.z = cam_ee_quat.z

    man_pose.position.x = man_ee_pos[1]
    man_pose.position.y = man_ee_pos[2]
    man_pose.position.z = man_ee_pos[3]
    man_pose.orientation.w = man_ee_quat.w
    man_pose.orientation.x = man_ee_quat.x
    man_pose.orientation.y = man_ee_quat.y
    man_pose.orientation.z = man_ee_quat.z

    publish(cam_pose_pub, cam_pose)
    publish(man_pose_pub, man_pose)

    solve_count += 1
    rossleep(loop_rate)
end

# end

# loop()
