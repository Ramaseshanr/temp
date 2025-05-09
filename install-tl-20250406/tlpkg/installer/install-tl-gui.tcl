#!/usr/bin/env wish

# Copyright 2018-2025 Siep Kroonenberg

# This file is licensed under the GNU General Public License version 2
# or any later version.

# Tcl/Tk frontend for TeX Live installer

# Installation can be divided into three stages:
#
# 1. preliminaries. This stage may involve some interaction with the user,
#    which can be channeled through message boxes
# 2. a menu
# 3. the actual installation
#
# During stage 1. and 3. this wrapper collects stdout and stderr from
# the perl installer, with stderr being redirected to stdout.
# This output will be displayed in a text widget during stage 3,
# and in debug mode also in stage 1.
# During stage 3, we shall use event-driven, non-blocking I/O, which is
# needed for a scrolling display of installer output.
#
# Main window:
# filled successively with:
# - a logo, and 'loading...' label, by way of splash
# - a menu for stage 2
# - a log text widget for tracking stage 3
#   ::out_log should be cleared before stage 3.
#
# In profile mode, the menu stage is skipped.

package require Tk

# security: disable send
catch {rename send {}}

# This file should be in $::instroot/tlpkg/installer.
# On non-windows platforms, install-tl functions as a wrapper
# for this file if it encounters a parameter '-gui' (but not -gui text).
# This allows automatic inclusion of a '--' parameter to separate
# tcl parameters from script parameters.

set ::instroot [file normalize [info script]]
set ::instroot [file dirname [file dirname [file dirname $::instroot]]]

# declarations, initializations and procs shared with tlshell.tcl.
# tltcl may want to know whether or not it was invoked by tlshell:
set ::invoker [file tail [info script]]
if [string match -nocase ".tcl" [string range $::invoker end-3 end]] {
  set ::invoker [string range $::invoker 0 end-4]
}
source [file join $::instroot "tlpkg" "tltcl" "tltcl.tcl"]
unset ::invoker

### initialize some globals ###

# perl installer process id
set ::perlpid 0

set ::out_log {}; # list of strings

set ::perlbin "perl"
if {$::tcl_platform(platform) eq "windows"} {
  # the batch wrapper should have put perl.exe on the searchpath
  set ::perlbin "perl.exe"
}

# menu modes
set ::advanced 0
set ::alltrees 0

# interactively select repository; default false
set ::select_repo 0

proc kill_perl {} {
  if $::perlpid {
    catch {
      if {$::tcl_platform(platform) eq "unix"} {
        exec -ignorestderr kill $::perlpid >& /dev/null
      } else {
        exec -ignorestderr taskkill /pid $::perlpid /t /f
      }
    }
  }
}

proc err_exit {{mess ""}} {
  if {$mess eq ""} {set mess "Error"}
  append mess "\n" [get_stacktrace]
  tk_messageBox -icon error -message $mess
  # kill perl process, just in case
  kill_perl
  exit
} ; # err_exit

# warning about non-empty target tree
set ::td_warned 0

proc is_nonempty {td} {
  if {! [file exists $td]} {return 0}
  return [expr {[llength [glob -nocomplain -directory $td *]] > 0}]
}

proc td_warn {td} {
  set ans [tk_messageBox -icon warning -type ok \
       -message [__ "Target directory %s non-empty;\nmay cause trouble!" $td]]
  set ::td_warned 1
}

proc td_question {td} {
  set ans [tk_messageBox -icon warning -type yesno \
       -message [__ "Target directory %s non-empty;\nare you sure?" $td]]
  set ::td_warned 1
  return $ans
}

### procedures, mostly organized bottom-up ###

# the procedures which provide the menu with the necessary backend data,
# i.e. read_descs, read_vars and read_menu_data, are defined near the end.

set clock0 [clock milliseconds]
set profiling 0
proc show_time {s} {
  if $::profiling {
    puts [format "%s: %d" $s [expr {[clock milliseconds] - $::clock0}]]
  }
}

# for debugging frontend-backend communication:
# write to a logfile which is shared with the backend.
# both parties open, append and close every time.

set dblogdir "/tmp"
if [info exists ::env(TMPDIR)] {
  set dblogdir $::env(TMPDIR)
} elseif [info exists ::env(TMP)] {
  set dblogdir $::env(TMP)
} elseif [info exists ::env(TEMP)] {
  set dblogdir $::env(TEMP)
}
set ::dblfile [file join $dblogdir "dblog"]
unset dblogdir

proc dblog {s} {
  set db [open $::dblfile a]
  set t [get_stacktrace]
  puts $db "TCL: $s\n$t"
  close $db
}

# welcome message now provided by install-tl

# regular read_line
proc read_line {} {
  while 1 {
    if [catch {chan gets $::inst l} len] {
      # catch [chan close $::inst]
      err_exit "
Error while reading from Perl back end.
This should not have happened!"
    } elseif {$len < 0} {
      # catch [chan close $::inst]
      return [list -1 ""]
    } elseif {[string range $l 0 1] eq "D:" || [string range $l 0 2] eq "DD:" \
               || [string range $l 0 3] eq "DDD:"} {
      lappend ::out_log $l
    } else {
      return [list $len $l]
    }
  }
}; # read_line

proc read_line_no_eof {} {
  set ll [read_line]
  if {[lindex $ll 0] < 0} {
    log_exit "
Unexpected closed backend.
This should not have happened!"
  }
  set l [lindex $ll 1]
  # TODO: test under debug mode
  return $l
}; # read_line_no_eof

# non-blocking i/o: callback for "readable" while the splash screen is up
# and the back end tries to contact the repository
proc read_line_loading {} {
  set l "" ; # will contain the line to be read
  if {([catch {chan gets $::inst l} len] || [chan eof $::inst])} {
    catch {chan close $::inst}
    # note. the normal way to terminate is terminating the GUI shell.
    # This closes stdin of the child
  } elseif {$len >= 0} {
    if {$l eq "endload"} {
      chan configure $::inst -blocking 1
      chan event $::inst readable {}
      set ::loaded 1
    }
  }
}; # read_line_loading

# non-blocking i/o: callback for "readable" during stage 3, installation
# ::out_log should no longer be needed
proc read_line_cb {} {
  set l "" ; # will contain the line to be read
  if {([catch {chan gets $::inst l} len] || [chan eof $::inst])} {
    catch {chan close $::inst}
    # note. the normal way to terminate is terminating the GUI shell.
    # This closes stdin of the child
    .close state !disabled
    if [winfo exists .abort] {.abort state disabled}
  } elseif {$len >= 0} {
    # regular output
    .log.tx configure -state normal
    .log.tx insert end "$l\n"
    .log.tx yview moveto 1
    if {$::tcl_platform(os) ne "Darwin"} {.log.tx configure -state disabled}
  }
}; # read_line_cb

proc maybe_abort {} {
  set ans [tk_messageBox -message [__ "Really abort?"] -type yesno \
               -default no]
  if {$ans eq "no"} {
    return
  }
  catch {chan close $::inst}
  kill_perl
  exit
}

# modify parameter list for either restarting gui installer
# or for starting back end

proc replace_lang_parameter {} {
  # edit original command line by removing any language parameter
  # and adding a repository parameter $m. same for language
  set i [llength $::argv]
  while {$i > 0} {
    incr i -1
    set p [lindex $::argv $i]
    if {$p eq "-lang" || $p eq "-gui-lang"} {
      set j [expr {$i+1}]
      if {$j < [llength $::argv]} {
        set ::argv [lreplace $::argv $i $j]
      } else {
        set ::argv [lreplace $::argv $i]
      }
      set ::argv [lreplace $::argv $i [expr {$i+1}]]
    }
  }
  lappend ::argv "-lang" $::lang
}

proc replace_repo_parameter {m} {
  # edit original command line by removing any repository parameter
  # and adding a repository parameter $m. same for language
  set i $::argc
  while {$i > 0} {
    incr i -1
    set p [lindex $::argv $i]
    if {$p in {"-location" "-url" "-repository" "-repos" "-repo"}} {
      set j [expr {$i+1}]
      if {$j < [llength $::argv]} {
        set ::argv [lreplace $::argv $i $j]
      } else {
        set ::argv [lreplace $::argv $i]
      }
    }
  }
  lappend ::argv "-repository" $m
}

# restart installer with chosen repository
proc restart_with_mir {m} {
  # edit original command line by removing any repository parameter
  # and adding a repository parameter $m. same for language
  replace_repo_parameter $m
  replace_lang_parameter
  set cmd [linsert $::argv 0 [info nameofexecutable] [info script] "--"]

  # terminate back end
  catch {chan close $::inst}
  kill_perl

  # restart install-tl with edited command-line
  exec {*}$cmd &
  exit
} ; # restart_with_mir

proc continue_with_mir {m} {
  replace_repo_parameter $m
  set ::mir_selected 1 ; # this will cause select_mirror to finish up
}

# add $::instroot as local repository if applicable
proc mirror_menu_plus {wnd cmd} {
  set have_local 0
  if [file isdirectory [file join $::instroot "archive"]] {
    set have_local 1
  } elseif [file readable \
                [file join $::instroot "texmf-dist" "web2c" "texmf.cnf"]] {
    set have_local 1
  }
  mirror_menu $wnd $cmd
  if {[winfo class $wnd] ne "TMenubutton"} {
    error_exit "No mirror list found"
  } else {
    if $have_local {
      $wnd.m insert 0 command -label "$::instroot ([__ "Local repository"])" \
          -command "$cmd $::instroot"
    }
  }
  return $wnd
}

##############################################################

##### special-purpose uses of main window: select_mirror, splash, log #####

proc pre_splash {} {
  # build splash window minus buttons
  wm withdraw .

  # picture and logo
  catch {
    image create photo tlimage -file \
        [file join $::instroot "tlpkg" "installer" "texlion.gif"]
    pack [frame .white -background white] -side top -fill x -expand 1
    label .image -image tlimage -background white
    pack .image -in .white
  }

  # wallpaper for remaining widgets
  pack [ttk::frame .bg -padding 3p] -fill both -expand 1

  # frame for buttons (abort button, mirrors dropdown menu)
  pack [ttk::frame .splfb] -in .bg -side bottom -fill x
}

proc select_mirror {} {

  # buttons: abort button, mirrors dropdown menu, continue
  ppack [mirror_menu_plus .splfb.slmir_m continue_with_mir] \
      -side right
  ppack [ttk::button .splfb.slmir_a -text [__ "Abort"] -command maybe_abort] \
      -side right

  update
  wm state . normal
  raise .
  vwait ::mir_selected
} ; # select_mirror

proc make_splash {} {
  wm withdraw .

  # we want this if select_mirror has run:
  foreach c [winfo children .splfb] {
    catch {destroy $c}
  }

  ppack [ttk::button .spl_a -text [__ "Abort"] -command maybe_abort] \
      -side right -in .splfb
  ppack [mirror_menu_plus .spl_o restart_with_mir] -side right -in .splfb

  # some text
  ppack [ttk::label .text -text [__ "TeX Live Installer"] \
             -font hfont] -in .bg
  if {! $::select_repo} {
    ppack [ttk::label .loading -text [__ "Trying to load %s.

If this takes too long, press Abort or choose another repository." \
                                          $::prelocation]] -in .bg
  }

  update
  wm state . normal
  raise .
}; # make_splash

# ATM ::out_log will be shown only at the end
proc show_log {{do_abort 0}} {
  wm withdraw .
  foreach c [winfo children .] {
    catch {destroy $c}
  }

  # wallpaper
  pack [ttk::frame .bg -padding 3p] -fill both -expand 1

  # buttons at bottom
  pack [ttk::frame .bottom] -in .bg -side bottom -fill x
  ttk::button .close -text [__ "Close"] -command exit
  ppack .close -in .bottom -side right
  if $do_abort {
    ttk::button .abort -text [__ "Abort"]  -command maybe_abort
    ppack .abort -in .bottom -side right
  }
  bind . <Escape> {
    if {[winfo exists .close] && ! [.close instate disabled]} {.close invoke}
  }

  # logs plus their scrollbars
  pack [ttk::frame .log] -in .bg -fill both -expand 1
  pack [ttk::scrollbar .log.scroll -command ".log.tx yview"] \
      -side right -fill y
  ppack [text .log.tx -height 20 -wrap word -font TkDefaultFont \
      -yscrollcommand ".log.scroll set"] \
      -expand 1 -fill both
  .log.tx configure -state normal
  .log.tx delete 1.0 end
  foreach l $::out_log {
    .log.tx insert end "$l\n"
  }
  if {$::tcl_platform(os) ne "Darwin"} {.log.tx configure -state disabled}
  .log.tx yview moveto 1

  wm resizable . 1 1
  wm overrideredirect . 0
  update
  wm state . normal
  raise .
}; # show_log

proc log_exit {{mess ""}} {
  if {$mess ne ""} {lappend ::out_log $mess}
  catch {chan close $::inst} ; # should terminate perl
  if {[llength $::out_log] > 0} {
    if {[llength $::out_log] < 10} {
      tk_messageBox -icon info -message [join $::out_log "\n"]
      exit
    } else {
      show_log ; # its close button exits
    }
  } else {
    exit
  }
}; # log_exit

##### installation root #####

proc update_full_path {} {
  set val [file join \
               [.tltd.prefix_l cget -text] \
               [.tltd.name_l cget -text] \
               [.tltd.rel_l cget -text]]
  set val [native_slashify $val]
  .tltd.path_l configure -text $val
  # ask perl to check path
  chan puts $::inst "checkdir"
  chan puts $::inst [forward_slashify [.tltd.path_l cget -text]]
  chan flush $::inst
  if {[read_line_no_eof] eq "0"} {
    .tltd.path_l configure -text \
        [__ "Cannot be created or cannot be written to"] \
        -foreground red
    .tltd.ok_b state disabled
  } else {
    .tltd.path_l configure -text $val -foreground $::blk
    .tltd.ok_b state !disabled
  }
  return
} ; # update_full_path

proc edit_name {} {
  create_dlg .tled .tltd
  wm title .tled [__ "Directory name..."]
  if $::plain_unix {wm attributes .tled -type dialog}

  # wallpaper
  pack [ttk::frame .tled.bg -padding 3p] -fill both -expand 1

  # widgets
  ttk::label .tled.l -text [__ "Change name (slashes not allowed)"]
  pack .tled.l -in .tled.bg -padx 5p -pady 5p
  ttk::entry .tled.e -width 20
  .tled.e state !disabled
  pack .tled.e -in .tled.bg -pady 5p
  .tled.e insert 0 [.tltd.name_l cget -text]

  # now frame with ok and cancel buttons
  pack [ttk::frame .tled.buttons] -in .tled.bg -fill x
  ttk::button .tled.ok_b -text [__ "Ok"] -command {
    if [regexp {[\\/]} [.tled.e get]] {
      tk_messageBox -type ok -icon error -message [__ "No slashes allowed"]
    } else {
      .tltd.name_l configure -text [.tled.e get]
      update_full_path
      end_dlg "" .tled
    }
  }
  ppack .tled.ok_b -in .tled.buttons -side right -padx 5p -pady 5p
  ttk::button .tled.cancel_b -text [__ "Cancel"] -command {end_dlg "" .tled}
  ppack .tled.cancel_b -in .tled.buttons -side right -padx 5p -pady 5p
  bind .tled <Escape> {.tled.cancel_b invoke}

  wm protocol .tled WM_DELETE_WINDOW \
      {cancel_or_destroy .tled.cancel_b .tled}
  wm resizable .tled 0 0
  place_dlg .tled .tltd
} ; # edit_name

proc toggle_rel {} {
  if {[.tltd.rel_l cget -text] ne ""} {
    set ans \
        [tk_messageBox -message \
             [__ "TL release component highly recommended!\nAre you sure?"] \
             -title [__ "Warning"] \
        -type yesno \
        -default no]
    if {$ans eq no} {
      return
    }
    .tltd.rel_l configure -text ""
    .tltd.sep1_l configure -text " "
    .tltd.rel_b configure -text [__ "Add year"]
  } else {
    .tltd.rel_l configure -text $::release_year
    .tltd.sep1_l configure -text [file separator]
    .tltd.rel_b configure -text [__ "Remove year"]
  }
  update_full_path
} ; # toggle_rel

proc commit_canonical_local {} {
  if {[file tail $::vars(TEXDIR)] eq $::release_year} {
    set l [file dirname $::vars(TEXDIR)]
  } else {
    set l $::vars(TEXDIR)
  }
  if {[forward_slashify $l] ne \
          [forward_slashify [file dirname $::vars(TEXMFLOCAL)]]} {
    set ::vars(TEXMFLOCAL) [forward_slashify [file join $l "texmf-local"]]
  }
}

proc commit_root {} {
  set td [.tltd.path_l cget -text]
  set ::td_warned 0
  if [is_nonempty $td] {
    if {[td_question $td] ne yes} return
  }
  set ::vars(TEXDIR) [forward_slashify [.tltd.path_l cget -text]]
  set ::vars(TEXMFSYSVAR) "$::vars(TEXDIR)/texmf-var"
  set ::vars(TEXMFSYSCONFIG) "$::vars(TEXDIR)/texmf-config"
  if [winfo exists .tspvl] {
    .tspvl configure -text [file join $::vars(TEXDIR) "texmf-dist"]
  }
  commit_canonical_local

  if {$::vars(instopt_portable)} {
    set ::vars(TEXMFHOME) $::vars(TEXMFLOCAL)
    set ::vars(TEXMFVAR) $::vars(TEXMFSYSVAR)
    set ::vars(TEXMFCONFIG) $::vars(TEXMFSYSCONFIG)
  }
  destroy .tltd
  update_vars
}

### main directory dialog ###

proc texdir_setup {} {

  ### widgets ###

  create_dlg .tltd .
  wm title .tltd [__ "Installation root"]

  # wallpaper
  pack [ttk::frame .tltd.bg -padding 3p] -expand 1 -fill both

  # full path
  pack [ttk::label .tltd.path_l -font lfont -anchor center] \
      -in .tltd.bg -pady 10p -fill x -expand 1

  # installation root components, gridded
  pack [ttk::frame .tltd.fr1 -borderwidth 2p -relief groove] \
      -in .tltd.bg -fill x -expand 1
  grid columnconfigure .tltd.fr1 0 -weight 1
  grid columnconfigure .tltd.fr1 2 -weight 1
  grid columnconfigure .tltd.fr1 4 -weight 1
  set rw -1
  # path components, as labels
  incr rw
  pgrid [ttk::label .tltd.prefix_l] -in .tltd.fr1 -row $rw -column 0
  pgrid [ttk::label .tltd.sep0_l -text "/"] \
      -in .tltd.fr1 -row $rw -column 1
  pgrid [ttk::label .tltd.name_l] -in .tltd.fr1 -row $rw -column 2
  pgrid [ttk::label .tltd.sep1_l -text "/"] \
      -in .tltd.fr1 -row $rw -column 3
  pgrid [ttk::label .tltd.rel_l -width 6] \
      -in .tltd.fr1 -row $rw -column 4
  # corresponding buttons
  incr rw
  set prefix_text [__ "Prefix"]
  pgrid [ttk::button .tltd.prefix_b -text "${prefix_text}... \u00B9" \
          -command {if [dirbrowser2widget .tltd.prefix_l] update_full_path}] \
      -in .tltd.fr1 -row $rw -column 0
  pgrid [ttk::button .tltd.name_b -text [__ "Change"] -command edit_name] \
      -in .tltd.fr1 -row $rw -column 2
  pgrid [ttk::button .tltd.rel_b -text [__ "Remove year"] \
      -command toggle_rel] \
      -in .tltd.fr1 -row $rw -column 4

  set note_text [__ "Prefix must exist"]
  ppack [ttk::label .tltd.notes -text "\u00B9 ${note_text}"] \
           -in .tltd.bg -fill x -anchor w

  # windows: note about localized names
  if {$::tcl_platform(platform) eq "windows"} {
    .tltd.prefix_b configure -text "${prefix_text}... \u00B9 \u00B2"
    set loc_text \
      [__ "Localized directory names will be replaced by their real names"]
    .tltd.notes configure -justify left \
      -text "\u00B9 ${note_text}\n\u00B2 ${loc_text}"
    ppack .tltd.notes -in .tltd.bg -fill x
  }

  # ok/cancel buttons
  pack [ttk::frame .tltd.frbt] -in .tltd.bg -pady {10p 0p} -fill x
  ttk::button .tltd.ok_b -text [__ "Ok"] -command commit_root
  ppack .tltd.ok_b -in .tltd.frbt -side right
  ttk::button .tltd.cancel_b -text [__ "Cancel"] \
             -command {destroy .tltd}
  ppack .tltd.cancel_b -in .tltd.frbt -side right
  bind .tltd <Escape> {.tltd.cancel_b invoke}

  ### initialization and callbacks ###

  set val [native_slashify [file normalize $::vars(TEXDIR)]]
  regsub {[\\/]$} $val {} val

  set initdir $val
  set name ""
  set rel ""

  # TL release subdirectory at the end?
  set rel_pat {[\\/](}
  append rel_pat  $::release_year {)$}
  if [regexp $rel_pat $initdir m rel] {
    set rel $::release_year
    regsub $rel_pat $initdir {} initdir
  }
  .tltd.rel_l configure -text $rel

  # next-last component
  regexp {^(.*)[\\/]([^\\/]*)$} $initdir m initdir name
  .tltd.name_l configure -text $name

  # backtrack remaining initdir to something that exists
  # and assign it to prefix
  set initprev ""
  while {! [file isdirectory $initdir]} {
    set initprev $initdir
    regexp {^(.*)[\\/]([^\\/]*)} $initdir m initdir m1
    if {$initprev eq $initdir} break
  }

  if {$initdir eq "" || \
          ($::tcl_platform(platform) eq "windows" && \
               [string index $initdir end] eq ":")} {
    append initdir "/"
  }
  .tltd.prefix_l configure -text $initdir
  update_full_path

  bind .tltd <Return> commit_root
  bind .tltd <Escape> {destroy .tltd}

  wm protocol .tltd  WM_DELETE_WINDOW \
      {cancel_or_destroy .tltd.cancel_b .tltd}
  wm resizable .tltd 1 0
  place_dlg .tltd
} ; # texdir_setup

##### other directories: TEXMFLOCAL, TEXMFHOME, portable #####

proc edit_dir {d} {
  create_dlg .td .
  wm title .td $d
  if $::plain_unix {wm attributes .td -type dialog}

  # wallpaper
  pack [ttk::frame .td.bg -padding 3p] -fill both -expand 1

  if {$d eq "TEXMFHOME"} {
    # explain tilde
    if {$::tcl_platform(platform) eq "windows"} {
      set ev "%USERPROFILE%"
      set xpl $::env(USERPROFILE)
    } else {
      set ev "\$HOME"
      set xpl $::env(HOME)
    }
    ppack [ttk::label .td.tilde \
               -text [__ "'~' equals %s, e.g. %s" $ev $xpl]] \
        -in .td.bg -anchor w
  }

  # other widgets

  ppack [ttk::entry .td.e -width 60] -in .td.bg -fill x
  .td.e insert 0 [native_slashify $::vars($d)]

  pack [ttk::frame .td.f] -fill x -expand 1
  ttk::button .td.ok -text [__ "Ok"] -command {end_dlg [.td.e get] .td}
  ppack .td.ok -in .td.f -side right
  ttk::button .td.cancel -text [__ "Cancel"] -command {end_dlg "" .td}
  ppack .td.cancel -in .td.f -side right
  bind .td <Escape> {.td.cancel invoke}

  wm protocol .td WM_DELETE_WINDOW \
      {cancel_or_destroy .td.cancel .td}
  wm resizable .td 1 0
  place_dlg .td .
  tkwait window .td
  if {[info exists ::dialog_ans] && $::dialog_ans ne ""} {
    set ::vars($d) [forward_slashify $::dialog_ans]
    if $::vars(instopt_portable) {
      if {$d eq "TEXMFLOCAL"} {set ::vars(TEXMFHOME) $::vars($d)}
      if {$d eq "TEXMFSYSVAR"} {set ::vars(TEXMFVAR) $::vars($d)}
      if {$d eq "TEXMFSYSCONFIG"} {set ::vars(TEXMFCONFIG) $::vars($d)}
      update
    }
  }
}

proc port_dis_or_activate {toggled} {
  if {!$::advanced} return
  set yn [yes_no $::vars(instopt_portable)]
  .dirportvl configure -text $yn
  if {$::vars(instopt_portable)} {
    set ::vars(TEXMFHOME) $::vars(TEXMFLOCAL)
    set ::vars(TEXMFVAR) $::vars(TEXMFSYSVAR)
    set ::vars(TEXMFCONFIG) $::vars(TEXMFSYSCONFIG)
    .thomeb state disabled
    if $::alltrees {
      .tvb state disabled
      .tcb state disabled
    }
    if {$::tcl_platform(platform) eq "windows"} {
      # adjust_path
      set ::vars(instopt_adjustpath) 0
      .pathb state disabled
      .pathl configure -foreground $::gry
      # desktop integration
      set ::vars(instopt_desktop_integration) 0
      .dkintb state disabled
      .dkintl configure -foreground $::gry
      # file associations
      set ::vars(instopt_file_assocs) 0
      .assocb state disabled
      .assocl configure -foreground $::gry
      # multi-user
      if $::is_admin {
        set ::vars(instopt_w32_multi_user) 0
        .adminb state disabled
        .adminl configure -foreground $::gry
      }
    } else {
      set ::vars(instopt_adjustpath) 0
      .symspec state disabled
      .pathb state disabled
      .pathl configure -foreground $::gry
    }
  } else {
    if $toggled {
      set ::vars(TEXMFHOME) "~/texmf"
      set ::vars(TEXMFVAR) "~/.texlive${::release_year}/texmf-var"
      set ::vars(TEXMFCONFIG) "~/.texlive${::release_year}/texmf-config"
    } ; # else leave alone
    #.tlocb state !disabled
    .thomeb state !disabled
    if $::alltrees {
      #.tsysvb state !disabled
      #.tsyscb state !disabled
      .tvb state !disabled
      .tcb state !disabled
    }
    if {$::tcl_platform(platform) eq "windows"} {
      # adjust_path
      set ::vars(instopt_adjustpath) 1
      .pathb state !disabled
      .pathl configure -foreground $::blk
      # desktop integration
      set ::vars(instopt_desktop_integration) 1
      .dkintb state !disabled
      .dkintl configure -foreground $::blk
      # file associations
      set ::vars(instopt_file_assocs) 1
      .assocb state !disabled
      .assocl configure -foreground $::blk
      # multi-user
      if $::is_admin {
        set ::vars(instopt_w32_multi_user) 1
        .adminb state !disabled
        .adminl configure -foreground $::blk
      }
    } else {
      # set ::vars(instopt_adjustpath) 0
      # leave false, still depends on symlink paths
      .symspec state !disabled
      if [dis_enable_symlink_option] {
        .pathb state !disabled
        .pathl configure -foreground $::blk
      }
    }
  }
}

proc toggle_port {} {
  set ::vars(instopt_portable) [expr {!$::vars(instopt_portable)}]
  port_dis_or_activate 1
  commit_canonical_local
}; # toggle_port

#############################################################

##### selections: binaries, scheme, collections #####

proc show_stats {} {
  # n. of additional platforms
  if [winfo exists .binlm] {
    if {$::vars(n_systems_selected) < 2} {
      .binlm configure -text [__ "None"]
    } else {
      .binlm configure -text [expr {$::vars(n_systems_selected) - 1}]
    }
  }
  # n. out of n. packages
  if [winfo exists .lcolv] {
    .lcolv configure -text \
        [format "%d / %d" \
             $::vars(n_collections_selected) \
             $::vars(n_collections_available)]
  }
  if [winfo exists .schml] {
    .schml configure -text [__ $::scheme_descs($::vars(selected_scheme))]
  }
  # diskspace: can use -textvariable here
  # paper size
}; # show_stats

#############################################################

### binaries ###

# toggle platform in treeview widget, but not in underlying data
proc toggle_bin {b} {
  if {$b eq $::vars(this_platform)} {
    tk_messageBox -message [__ "Cannot deselect own platform"]
    return
  }
  set m [.tlbin.lst set $b "mk"]
  if {$m eq [mark_sym 0]} {
    .tlbin.lst set $b "mk" [mark_sym 1]
  } else {
    .tlbin.lst set $b "mk" [mark_sym 0]
  }
}; # toggle_bin

proc save_bin_selections {} {
  set ::vars(n_systems_selected) 0
  foreach b [.tlbin.lst children {}] {
    set bb "binary_$b"
    if {[.tlbin.lst set $b "mk"] ne [mark_sym 0]} {
      incr ::vars(n_systems_selected)
      set ::vars($bb) 1
    } else {
      set ::vars($bb) 0
    }
    if {$b eq "win32"} {
      set ::vars(collection-wintools) $::vars($bb)
    }
  }
  update_vars
  show_stats
}; # save_bin_selections

proc sort_bins_by_value {n m} {
  return [string compare [__ $::bin_descs($n)] [__ $::bin_descs($m)]]
}

proc select_binaries {} {
  create_dlg .tlbin .
  wm title .tlbin [__ "Binaries"]

  # wallpaper
  pack [ttk::frame .tlbin.bg -padding 3p] -expand 1 -fill both

  # ok, cancel buttons
  pack [ttk::frame .tlbin.buts] -in .tlbin.bg -side bottom -fill x
  ttk::button .tlbin.ok -text [__ "Ok"] -command \
      {save_bin_selections; update_vars; end_dlg 1 .tlbin}
  ppack .tlbin.ok -in .tlbin.buts -side right
  ttk::button .tlbin.cancel -text [__ "Cancel"] -command {end_dlg 0 .tlbin}
  ppack .tlbin.cancel -in .tlbin.buts -side right
  bind .tlbin <Escape> {.tlbin.cancel invoke}

  # treeview for binaries, with checkbox column and vertical scrollbar
  pack [ttk::frame .tlbin.binsf] -in .tlbin.bg -expand 1 -fill both

  ttk::treeview .tlbin.lst -columns {mk desc} -show {} \
      -selectmode extended -yscrollcommand {.tlbin.binsc set}

  ttk::scrollbar .tlbin.binsc -orient vertical -command {.tlbin.lst yview}
  .tlbin.lst column mk -stretch 0 -width [expr {$::cw * 3}]
  .tlbin.lst column desc -stretch 1
  foreach b [lsort -command sort_bins_by_value [array names ::bin_descs]] {
    set bb "binary_$b"
    .tlbin.lst insert {}  end -id $b -values \
        [list [mark_sym $::vars($bb)] [__ $::bin_descs($b)]]
  }
  set_tree_col_width .tlbin.lst "desc"
  pgrid .tlbin.lst -in .tlbin.binsf -row 0 -column 0 -sticky news
  pgrid .tlbin.binsc -in .tlbin.binsf -row 0 -column 1 -sticky ns
  grid columnconfigure .tlbin.binsf 0 -weight 1
  grid rowconfigure .tlbin.binsf 0 -weight 1
  bind .tlbin.lst <space> {toggle_bin [.tlbin.lst focus]}
  bind .tlbin.lst <Return> {toggle_bin [.tlbin.lst focus]}
  bind .tlbin.lst <ButtonRelease-1> \
      {toggle_bin [.tlbin.lst identify item %x %y]}

  wm protocol .tlbin WM_DELETE_WINDOW \
      {cancel_or_destroy .tlbin.cancel .tlbin}
  wm resizable .tlbin 1 1
  place_dlg .tlbin .
}; # select_binaries

#############################################################

### scheme ###

proc select_scheme {} {
  create_dlg .tlschm .
  wm title .tlschm [__ "Schemes"]

  # wallpaper
  pack [ttk::frame .tlschm.bg -padding 3p] -fill both -expand 1

  # buttons at bottom
  pack [ttk::frame .tlschm.buts] -in .tlschm.bg -side bottom -fill x
  ttk::button .tlschm.ok -text [__ "Ok"] -command {
    # tree selection is a list:
    set ::vars(selected_scheme) [lindex [.tlschm.lst selection] 0]
    foreach v [array names ::vars] {
      if {[string range $v 0 6] eq "scheme-"} {
        if {$v eq $::vars(selected_scheme)} {
          set ::vars($v) 1
        } else {
          set ::vars($v) 0
        }
      }
    }
    update_vars
    show_stats
    end_dlg 1 .tlschm
  }
  ppack .tlschm.ok -in .tlschm.buts -side right
  ttk::button .tlschm.cancel -text [__ "Cancel"] -command {end_dlg 0 .tlschm}
  ppack .tlschm.cancel -in .tlschm.buts -side right
  bind .tlschm <Escape> {.tlschm.cancel invoke}

  # schemes list. use treeview rather than listbox for uniform formatting
  ttk::treeview .tlschm.lst -columns {desc} -show {} -selectmode browse \
      -height [llength $::schemes_order]
  ppack .tlschm.lst -in .tlschm.bg -fill both -expand 1
  foreach s $::schemes_order {
    .tlschm.lst insert {} end -id $s -values [list [__ $::scheme_descs($s)]]
  }
  set_tree_col_width .tlschm.lst "desc"
  # we already made sure that $::vars(selected_scheme) has a valid value
  .tlschm.lst selection set [list $::vars(selected_scheme)]

  wm protocol .tlschm WM_DELETE_WINDOW \
      {cancel_or_destroy tlschm.cancel .tlschm}
  wm resizable .tlschm 1 0
  place_dlg .tlschm .
}; # select_scheme

#############################################################

### collections ###

# toggle collection in treeview widget, but not in underlying data
proc toggle_coll {cs c} {
  # cs: treeview widget; c: selected child item
  set m [$cs set $c "mk"]
  if {$m eq [mark_sym 0]} {
    $cs set $c "mk" [mark_sym 1]
  } else {
    $cs set $c "mk" [mark_sym 0]
  }
}; # toggle_coll

proc save_coll_selections {} {
  foreach wgt {.tlcoll.other .tlcoll.lang} {
    foreach c [$wgt children {}] {
      if {[$wgt set $c "mk"] eq [mark_sym 0]} {
        set ::vars($c) 0
      } else {
        set ::vars($c) 1
      }
    }
  }
  set ::vars(selected_scheme) "scheme-custom"
  update_vars
  show_stats
}; # save_coll_selections

proc sort_colls_by_value {n m} {
  return [string compare [__ $::coll_descs($n)] [__ $::coll_descs($m)]]
}

proc select_collections {} {
  # 2018: more than 40 collections
  # The tcl installer acquires collections from install-menu-extl.pl,
  # but install-tl also has an array of collections.
  # Use treeview for checkbox column and display of
  # collection descriptions rather than names.
  # buttons: select all, select none, ok, cancel
  # should some collections be excluded? Check install-menu-* code.
  create_dlg .tlcoll .
  wm title .tlcoll [__ "Collections"]

  # wallpaper
  pack [ttk::frame .tlcoll.bg -padding 3p] -fill both -expand 1

  # frame at bottom with ok and cancel buttons
  pack [ttk::frame .tlcoll.butf] -in .tlcoll.bg -side bottom -fill x
  ttk::button .tlcoll.ok -text [__ "Ok"] -command \
      {save_coll_selections; end_dlg 1 .tlcoll}
  ppack .tlcoll.ok -in .tlcoll.butf -side right
  ttk::button .tlcoll.cancel -text [__ "Cancel"] -command {end_dlg 0 .tlcoll}
  ppack .tlcoll.cancel -in .tlcoll.butf -side right
  bind .tlcoll <Escape> {.tlcoll.cancel invoke}

  # Treeview and scrollbar for non-language- and language collections resp.
  pack [ttk::frame .tlcoll.both] -in .tlcoll.bg -expand 1 -fill both

  foreach t {"lang" "other"} {

    # frames with select all/none buttons, separately for lang and others
    set wgb .tlcoll.b$t
    ttk::frame $wgb
    ttk::label ${wgb}sel -text [__ "Select"]
    ttk::button ${wgb}all -text [__ "All"] -padding 1p -command \
      "foreach c \[.tlcoll.$t children {}\] \{
        .tlcoll.$t set \$c mk \[mark_sym 1\]\}"
    ttk::button ${wgb}none -text [__ "None"] -padding 1p -command \
      "foreach c \[.tlcoll.$t children {}\] \{
        .tlcoll.$t set \$c mk \[mark_sym 0\]\}"
    pack ${wgb}sel ${wgb}all ${wgb}none -in $wgb \
        -side left -padx 3p -pady 3p

    # trees with collections and markers, lang and other separately
    set wgt ".tlcoll.$t"
    ttk::treeview $wgt -columns {mk desc} -show {headings} \
        -selectmode extended -yscrollcommand "${wgt}sc set"
    $wgt heading "mk" -text ""
    if {$t eq "lang"} {
      $wgt heading "desc" -text [__ "Languages"]
    } else {
      $wgt heading "desc" -text [__ "Other collections"]
    }
    # and their vertical scrollbars
    ttk::scrollbar ${wgt}sc -orient vertical -command "$wgt yview"
    $wgt column mk -width [expr {$::cw * 3}] -stretch 0
    $wgt column desc -stretch 1

    bind $wgt <space> {toggle_coll %W [%W focus]}
    bind $wgt <Return> {toggle_coll %W [%W focus]}
    bind $wgt <ButtonRelease-1> {toggle_coll %W [%W identify item %x %y]}
  }
  grid .tlcoll.blang x .tlcoll.bother -in .tlcoll.both -sticky w
  grid .tlcoll.lang .tlcoll.langsc .tlcoll.other .tlcoll.othersc \
      -in .tlcoll.both
  grid columnconfigure .tlcoll.both 0 -weight 1
  grid columnconfigure .tlcoll.both 1 -weight 0
  grid columnconfigure .tlcoll.both 2 -weight 2
  grid columnconfigure .tlcoll.both 3 -weight 0
  grid configure .tlcoll.lang .tlcoll.other .tlcoll.langsc .tlcoll.othersc \
      -sticky nsew
  grid rowconfigure .tlcoll.both 1 -weight 1


  foreach c [lsort -command sort_colls_by_value [array names ::coll_descs]] {
    if [string equal -length 15 "collection-lang" $c] {
      set wgt ".tlcoll.lang"
    } else {
      set wgt ".tlcoll.other"
    }
    $wgt insert {} end -id $c -values \
        [list [mark_sym $::vars($c)] [__ $::coll_descs($c)]]
  }
  set_tree_col_width .tlcoll.lang "desc"
  set_tree_col_width .tlcoll.other "desc"

  wm protocol .tlcoll WM_DELETE_WINDOW \
      {cancel_or_destroy .tlcoll.cancel .tlcoll}
  wm resizable .tlcoll 1 1
  place_dlg .tlcoll .
}; # select_collections

##################################################

# option handling

# for multi-value options:
# below, $c is a combobox with values $l. The index of the current value in $l
# corresponds to the value of $::vars($v).

proc var2combo {v c} {
  $c current $::vars($v)
}
proc combo2var {c v} {
  set ::vars($v) [$c current]
}
# if the variable has an impact on what to install:
proc combo2var_calc {c v} {
  combo2var c v
  update_vars
  show_stats
}

##### desktop integration; platform-specific #####

if {$::tcl_platform(platform) ne "windows"} {

  ### symlinks into standard directories ###

  # 'file writable' is only a check of unix permissions
  # use proc dir_writable instead
  proc dest_ok {d} {
    if {$d eq ""} {return 0}
    set its 1
    while 1 {
    if [file exists $d] {
      if {! [file isdirectory $d]} {
        return 0
      } elseif {! [dir_writable $d]} {
        return 0
      } else {
        return 1
      }
    } ; # if file exists
    # try a level up
    set d [file dirname $d]
    set its [expr {$its + 1}]
      if {$its > 3} {return 0}
    }
    return 0
  }

  proc dis_enable_symlink_option {} {
    set ok 1
    foreach v {"bin" "man" "info"} {
      set vv "tlpdbopt_sys_$v"
      if {! [info exists ::vars($vv)]} {set ok 0; break}
      set d $::vars($vv)
      if {![dest_ok $d]} {set ok 0; break}
    }
    if {$ok && !$::vars(instopt_portable)} {
      .pathb state !disabled
      .pathl configure -foreground $::blk
    } else {
      set ok 0
      .pathb state disabled
      .pathl configure -foreground $::gry
      set ::vars(instopt_adjustpath) 0
    }
    return $ok
  }

  # check validity of all three proposed symlink target directories.
  # do not dis/enable .pathb until return from .edsyms dialog.
  proc check_sym_entries {} {
    set ok 1
    foreach v {"bin" "man" "info"} {
      if [dest_ok [.edsyms.${v}e get]] {
        .edsyms.${v}mk configure -text "\u2714" -foreground $::blk
      } else {
        .edsyms.${v}mk configure -text "\u2718" -foreground red
        set ok 0
      }
    }
    if $ok {
      .edsyms.warn configure -text ""
    } else {
      .edsyms.warn configure -text \
          [__ "Warning. Not all configured directories are writable!"]
    }
  }

  proc commit_sym_entries {} {
    foreach v {"bin" "man" "info"} {
      set vv "tlpdbopt_sys_$v"
      set ::vars($vv) [.edsyms.${v}e get]
      if {[string index $::vars($vv) 0] eq "~"} {
        set ::vars($vv) "$::env(HOME)[string range $::vars($vv) 1 end]"
      }
    }
    if [dis_enable_symlink_option] {
      set ::vars(instopt_adjustpath) 1
    }
  }

  proc edit_symlinks {} {

    create_dlg .edsyms .
    wm title .edsyms [__ "Symlinks"]

    pack [ttk::frame .edsyms.bg -padding 3p] -expand 1 -fill both
    set rw -1

    pack [ttk::frame .edsyms.fr0] -in .edsyms.bg -expand 1 -fill both
    foreach v {"bin" "man" "info"} {
      incr rw
      # description
      pgrid [ttk::label .edsyms.${v}l -text ""] \
          -in .edsyms.fr0 -row $rw -column 0 -sticky e
      # ok mark
      pgrid [ttk::label .edsyms.${v}mk -text ""] \
          -in .edsyms.fr0 -row $rw -column 1
      # entry widget
      pgrid [ttk::entry .edsyms.${v}e -width 40] \
          -in .edsyms.fr0 -row $rw -column 2
      set vv "tlpdbopt_sys_$v"
      if [info exists ::vars($vv)] {
        .edsyms.${v}e insert 0 $::vars($vv)
      }; # else leave empty
      bind .edsyms.${v}e <KeyRelease> {+check_sym_entries}
      # browse button
      pgrid [ttk::button .edsyms.${v}br -text [__ "Browse..."] -command \
                 "dirbrowser2widget .edsyms.${v}e; check_sym_entries"] \
         -in .edsyms.fr0 -row $rw -column 3
    }
    .edsyms.binl configure -text [__ "Binaries"]
    .edsyms.manl configure -text [__ "Man pages"]
    .edsyms.infol configure -text [__ "Info pages"]

    # warning about read-only target directories
    incr rw
    pgrid [ttk::label .edsyms.warn -foreground red] \
        -in .edsyms.fr0 -column 2 -columnspan 2 -sticky w

    grid columnconfigure .edsyms.fr0 0 -weight 0
    grid columnconfigure .edsyms.fr0 1 -weight 0
    grid columnconfigure .edsyms.fr0 2 -weight 1
    grid columnconfigure .edsyms.fr0 3 -weight 0

    # ok, cancel
    pack [ttk::frame .edsyms.fr1] -expand 1 -fill both
    ppack [ttk::button .edsyms.ok -text [__ "Ok"] -command {
      commit_sym_entries; end_dlg 1 .edsyms}] -in .edsyms.fr1 -side right
    ppack [ttk::button .edsyms.cancel -text [__ "Cancel"] -command {
      end_dlg 0 .edsyms}] -in .edsyms.fr1 -side right
    bind .edsyms <Escape> {.edsyms.cancel invoke}

    check_sym_entries

    wm protocol .edsyms  WM_DELETE_WINDOW \
        {cancel_or_destroy .edsyms.cancel .edsyms}
    wm resizable .edsyms 1 0
    place_dlg .edsyms .
  } ; # edit_symlinks
} ; # $::tcl_platform(platform) ne "windows"

#############################################################

proc set_language {l} {
  set ::lang $l
  load_translations
  run_menu
}

proc set_fontscale {s} {
  set ::tkfontscale $s
  redo_fonts
  run_menu
}

proc zoom {n} {
  if {$n <= 0} {set n 1}
  set_fontscale [expr {$n*$::tkfontscale}]
}

# menus: disable tearoff feature
option add *Menu.tearOff 0

#############################################################

# the main menu interface will at certain events send the current values of
# the ::vars array to install-tl[-tcl], which will send back an updated version
# of this array.
# We still use blocking i/o: frontend and backend wait for each other.

## default_bg color, only used for menus under ::plain_unix
if [catch {ttk::style lookup TFrame -background} ::default_bg] {
  set ::default_bg white
}

proc abort_menu {} {
  set ::out_log {}
  set ::menu_ans "no_inst"
  # i.e. anything but advanced, alltrees or startinst
}

proc maybe_install {} {
  if {($::vars(free_size)!=-1) && \
          ($::vars(total_size) >= ($::vars(free_size)-100))} {
    tk_messageBox -icon error -message [__ "Not enough room"]
  } else {
    set ::menu_ans "startinst"
  }
}

proc run_menu {} {
  #if [info exists ::env(dbgui)] {
  #  puts "\ndbgui: run_menu: advanced is now $::advanced"
  #  puts "dbgui: run_menu: alltrees is now $::alltrees"
  #}
  wm withdraw .
  foreach c [winfo children .] {
    catch {destroy $c}
  }

  if $::plain_unix {
    # plain_unix: avoid a possible RenderBadPicture error on quitting
    # when there is a menu.
    # 'send' bypasses the bug by changing the shutdown sequence.
    # 'tk appname <something>' restores 'send'.
    bind . <Destroy> {
      catch {tk appname appname}
    }
  }

  # name in titlebar; should be redefined after any language switch
  wm title . [__ "TeX Live Installer"]

  # menu, for language selection and font scaling
  menu .mn
  . configure -menu .mn
  if $::plain_unix {
    .mn configure -borderwidth 1p
    .mn configure -background $::default_bg
  }
  .mn add command -command abort_menu -label [__ "Abort"]


  if {[llength $::langs] > 1} {
    menu .mn.lang
    .mn add cascade -label [__ "GUI language"] -menu .mn.lang
    foreach l [lsort $::langs] {
      if {$l eq $::lang} {
        set mlabel "$l *"
      } else {
        set mlabel $l
      }
      .mn.lang add command -label $mlabel -command "set_language $l"
    }
  }

  menu .mn.fscale
  .mn add cascade -label [__ "Font scaling"] -menu .mn.fscale
  .mn.fscale add command -label \
      "[__ "Current:"] [format { %.2f} $::tkfontscale]"
  foreach s {0.6 0.8 1 1.2 1.6 2 2.5 3 3.8 5 6 7.5 9} {
    .mn.fscale add command -label $s -command "set_fontscale $s"
  }

  # browser-style keyboard shortcuts for scaling
  bind . <Control-KeyRelease-minus> {zoom 0.8}
  bind . <Control-KeyRelease-equal> {zoom 1.25}
  bind . <Control-Shift-KeyRelease-equal> {zoom 1.25}
  bind . <Control-KeyRelease-plus> {zoom 1.25}
  bind . <Control-KeyRelease-0> {set_fontscale 1}
  if {$::tcl_platform(os) eq "Darwin"} {
    bind . <Command-KeyRelease-minus> {zoom 0.8}
    bind . <Command-KeyRelease-equal> {zoom 1.25}
    bind . <Command-Shift-KeyRelease-equal> {zoom 1.25}
    bind . <Command-KeyRelease-plus> {zoom 1.25}
    bind . <Command-KeyRelease-0> {set_fontscale 1}
  }

  # wallpaper, for a uniform background
  pack [ttk::frame .bg -padding 3p] -fill both -expand 1

  # title
  ttk::label .title -text [__ "TeX Live %s Installer" $::release_year] \
      -font titlefont
  pack .title -pady {10p 1p} -in .bg
  pack [ttk::label .svn -text "r. $::svn"] -in .bg

  pack [ttk::separator .seph0 -orient horizontal] \
      -in .bg -pady 3p -fill x

  # frame at bottom with install/quit buttons
  pack [ttk::frame .final] \
      -in .bg -side bottom -pady {5p 2p} -fill x
  ppack [ttk::button .install -text [__ "Install"] -command maybe_install] \
    -in .final -side right
  ppack [ttk::button .quit -text [__ "Quit"] -command {
    set ::out_log {}
    set ::menu_ans "no_inst"}] -in .final -side right
  bind . <Escape> whataboutclose
  if {!$::advanced} {
    ppack [ttk::button .adv -text [__ "Advanced"] -command {
      set ::menu_ans "advanced"
      #if [info exists ::env(dbgui)] {puts "dbgui: requested advanced"}
    }] -in .final -side left
  }
  pack [ttk::separator .seph1 -orient horizontal] \
      -in .bg -side bottom -pady 3p -fill x

  # directories, selections
  # advanced and basic have different frame setups
  if $::advanced {
    pack [ttk::frame .left] -in .bg -side left -fill both -expand 1
    set curf .left
  } else {
    pack [ttk::frame .main] -in .bg -side top -fill both -expand 1
    set curf .main
  }

  # directory section
  pack [ttk::frame .dirf] -in $curf -fill x
  grid columnconfigure .dirf 1 -weight 1
  set rw -1

  if $::advanced {
    incr rw
    # labelframes do not look quite right on macos,
    # instead, separate label widget for title
    pgrid [ttk::label .dirftitle -text [__ "Installation root"] \
               -font hfont] \
        -in .dirf -row $rw -column 0 -columnspan 3 -sticky w
    .dirftitle configure -text [__ "Directories"]
  }

  incr rw
  pgrid [ttk::label .tdirll] -in .dirf -row $rw -column 0 -sticky nw
  set s [__ "Installation root"]
  if $::advanced {
    .tdirll configure -text "TEXDIR:\n$s"
  } else {
    .tdirll configure -text $s
  }
  pgrid [ttk::label .tdirvl -textvariable ::vars(TEXDIR)] \
      -in .dirf -row $rw -column 1 -sticky nw
  pgrid [ttk::button .tdirb -text [__ "Change"] -command texdir_setup] \
    -in .dirf -row $rw -column 2 -sticky new

  if $::advanced {
    if $::alltrees {
      incr rw
      pgrid [ttk::label .tspll -text [__ "Main tree"]] \
          -in .dirf -row $rw -column 0 -sticky nw
      pgrid [ttk::label .tspvl] -in .dirf -row $rw -column 1 -sticky nw
      .tspvl configure -text [file join $::vars(TEXDIR) "texmf-dist"]

      incr rw
      pgrid [ttk::label .tsysvll -text "TEXMFSYSVAR"] \
          -in .dirf -row $rw -column 0 -sticky nw
      pgrid [ttk::label .tsysvvl -textvariable ::vars(TEXMFSYSVAR)] \
          -in .dirf -row $rw -column 1 -sticky nw
      ttk::button .tsysvb -text [__ "Change"] -command {edit_dir "TEXMFSYSVAR"}
      pgrid .tsysvb -in .dirf -row $rw -column 2 -sticky new

      incr rw
      pgrid [ttk::label .tsyscll -text "TEXMFSYSCONFIG"] \
          -in .dirf -row $rw -column 0 -sticky nw
      pgrid [ttk::label .tsyscvl -textvariable ::vars(TEXMFSYSCONFIG)] \
          -in .dirf -row $rw -column 1 -sticky nw
      ttk::button .tsyscb -text [__ "Change"] \
          -command {edit_dir "TEXMFSYSCONFIG"}
      pgrid .tsyscb -in .dirf -row $rw -column 2 -sticky new
    }
    incr rw
    set s [__ "Local additions"]
    pgrid [ttk::label .tlocll -text "TEXMFLOCAL:\n$s"] \
        -in .dirf -row $rw -column 0 -sticky nw
    pgrid [ttk::label .tlocvl -textvariable ::vars(TEXMFLOCAL)] \
        -in .dirf -row $rw -column 1 -sticky nw
    ttk::button .tlocb -text [__ "Change"] -command {edit_dir "TEXMFLOCAL"}
    pgrid .tlocb -in .dirf -row $rw -column 2 -sticky new

    incr rw
    set s [__ "Per-user additions"]
    pgrid [ttk::label .thomell -text "TEXMFHOME:\n$s"] \
        -in .dirf -row $rw -column 0 -sticky nw
    pgrid [ttk::label .thomevl -textvariable ::vars(TEXMFHOME)] \
        -in .dirf -row $rw -column 1 -sticky nw
    ttk::button .thomeb -text [__ "Change"] -command {edit_dir "TEXMFHOME"}
    pgrid .thomeb -in .dirf -row $rw -column 2 -sticky ne
    if $::alltrees {
      incr rw
      pgrid [ttk::label .tvll -text "TEXMFVAR"] \
          -in .dirf -row $rw -column 0 -sticky nw
      pgrid [ttk::label .tvvl -textvariable ::vars(TEXMFVAR)] \
          -in .dirf -row $rw -column 1 -sticky nw
      ttk::button .tvb -text [__ "Change"] -command {edit_dir "TEXMFVAR"}
      pgrid .tvb -in .dirf -row $rw -column 2 -sticky new
      incr rw
      pgrid [ttk::label .tcll -text "TEXMFCONFIG"] \
          -in .dirf -row $rw -column 0 -sticky nw
      pgrid [ttk::label .tcvl -textvariable ::vars(TEXMFCONFIG)] \
          -in .dirf -row $rw -column 1 -sticky nw
      ttk::button .tcb -text [__ "Change"] \
          -command {edit_dir "TEXMFCONFIG"}
      pgrid .tcb -in .dirf -row $rw -column 2 -sticky new
    }

    incr rw
    if {!$::alltrees} {
      ttk::button .tmoreb -text [__ "More ..."] -command {
        set ::menu_ans "alltrees"
        #if [info exists ::env(dbgui)] {puts "dbgui: requested alltrees"}
      }
      pgrid .tmoreb -in .dirf -row $rw -column 2 -sticky ne
    }

    incr rw
    pgrid [ttk::label .dirportll \
        -text [__ "Portable setup:\nMay reset TEXMFLOCAL\nand TEXMFHOME"]] \
        -in .dirf -row $rw -column 0 -sticky nw
    pgrid [ttk::label .dirportvl] -in .dirf -row $rw -column 1 -sticky nw
    pgrid [ttk::button .tportb -text [__ "Toggle"] -command toggle_port] \
      -in .dirf -row $rw -column 2 -sticky ne
    .dirportvl configure -text [yes_no $::vars(instopt_portable)]

    # platforms section
    if {$::tcl_platform(platform) ne "windows"} {
      pack [ttk::frame .platf] -in .left -fill x
      grid columnconfigure .platf 1 -weight 1
      set rw -1

      incr rw
      pgrid [ttk::label .binftitle -text [__ "Platforms"] -font hfont] \
        -in .platf -row $rw -column 0 -columnspan 3 -sticky w

      # current platform
      incr rw
      ttk::label .binl0 \
          -text [__ "Current platform:"]
      pgrid .binl0 -in .platf -row $rw -column 0 -sticky w
      ttk::label .binl1 \
          -text [__ "$::bin_descs($::vars(this_platform))"]
      pgrid .binl1 -in .platf -row $rw -column 1 -sticky w
      # additional platforms
      incr rw
      pgrid [ttk::label .binll -text [__ "N. of additional platform(s):"]] \
          -in .platf -row $rw -column 0 -sticky w
      pgrid [ttk::label .binlm] -in .platf -row $rw -column 1 -sticky w
      pgrid [ttk::button .binb -text [__ "Change"] -command select_binaries] \
          -in .platf -row $rw -column 2 -sticky e
    }

    # Selections section
    pack [ttk::frame .selsf] -in .left -fill x
    grid columnconfigure .selsf 1 -weight 1
    set rw -1

    incr rw
    pgrid [ttk::label .selftitle -text [__ "Selections"] -font hfont] \
        -in .selsf -row $rw -column 0 -columnspan 3 -sticky w

    # schemes
    incr rw
    pgrid [ttk::label .schmll -text [__ "Scheme:"]] \
        -in .selsf -row $rw -column 0 -sticky w
    pgrid [ttk::label .schml -text ""] \
        -in .selsf -row $rw -column 1 -sticky w
    pgrid [ttk::button .schmb -text [__ "Change"] -command select_scheme] \
        -in .selsf -row $rw -column 2 -sticky e

    # collections
    incr rw
    pgrid [ttk::label .lcoll -text [__ "N. of collections:"]] \
        -in .selsf -row $rw -column 0 -sticky w
    pgrid [ttk::label .lcolv] -in .selsf -row $rw -column 1 -sticky w
    pgrid [ttk::button .collb -text [__ "Customize"] \
               -command select_collections] \
        -in .selsf -row $rw -column 2 -sticky e
  }

  # total size and available space
  # curf: current frame
  set curf [expr {$::advanced ? ".selsf" : ".dirf"}]
  incr rw
  ttk::label .lsize -text [__ "Disk space required (in MB):"]
  ttk::label .size_req -textvariable ::vars(total_size)
  pgrid .lsize -in $curf -row $rw -column 0 -sticky w
  pgrid .size_req -in $curf -row $rw -column 1 -sticky w
  if {$::vars(free_size) != -1} {
    incr rw
    ttk::label .lavail -text [__ "Disk space available (in MB):"]
    ttk::label .avail -textvariable ::vars(free_size)
    pgrid .lavail -in $curf -row $rw -column 0 -sticky w
    pgrid .avail -in $curf -row $rw -column 1 -sticky w
  }

  ########################################################
  # right side: options
  # 3 columns. Column 1 can be merged with either 0 or 2.

  if $::advanced {

    pack [ttk::separator .sepv -orient vertical] \
        -in .bg -side left -padx 3p -fill y
    pack [ttk::frame .options] -in .bg -side right -fill both -expand 1

    set curf .options
    grid columnconfigure .options 0 -weight 1
    set rw -1

    incr rw
    pgrid [ttk::label .optitle -text [__ "Options"] -font hfont] \
        -in $curf -row $rw -column 0 -columnspan 3 -sticky w
  } else {
    set curf .dirf
  }

  # instopt_letter
  set ::lpapers {"A4" "Letter"}
  incr rw
  pgrid [ttk::label .paperl -text [__ "Default paper size"]] \
      -in $curf -row $rw -column 0 -sticky w
  pgrid [ttk::combobox .paperb -values $::lpapers -state readonly -width 8] \
      -in $curf -row $rw -column 1 -columnspan 2 -sticky e
  var2combo "instopt_letter" .paperb
  bind .paperb <<ComboboxSelected>> {+combo2var .paperb "instopt_letter"}

  if $::advanced {
    # instopt_write18_restricted
    incr rw
    pgrid [ttk::label .write18l -text \
        [__ "Allow execution of restricted list of programs via \\write18"]] \
        -in $curf -row $rw -column 0 -columnspan 2 -sticky w
    ttk::checkbutton .write18b -variable ::vars(instopt_write18_restricted)
    pgrid .write18b -in $curf -row $rw -column 2 -sticky e

    # tlpdbopt_create_formats
    incr rw
    pgrid [ttk::label .formatsl -text [__ "Create all format files"]] \
        -in $curf -row $rw -column 0 -columnspan 2 -sticky w
    ttk::checkbutton .formatsb -variable ::vars(tlpdbopt_create_formats)
    pgrid .formatsb -in $curf -row $rw -column 2 -sticky e

    # tlpdbopt_install_docfiles
    if $::vars(doc_splitting_supported) {
      incr rw
      pgrid [ttk::label .docl -text [__ "Install font/macro doc tree"]] \
          -in $curf -row $rw -column 0 -columnspan 2 -sticky w
      ttk::checkbutton .docb -variable ::vars(tlpdbopt_install_docfiles) \
          -command {update_vars; show_stats}
      pgrid .docb -in $curf -row $rw -column 2 -sticky e
    }

    # tlpdbopt_install_srcfiles
    if $::vars(src_splitting_supported) {
      incr rw
      pgrid [ttk::label .srcl -text [__ "Install font/macro source tree"]] \
          -in $curf -row $rw -column 0 -columnspan 2 -sticky w
      ttk::checkbutton .srcb -variable ::vars(tlpdbopt_install_srcfiles) \
          -command {update_vars; show_stats}
      pgrid .srcb -in $curf -row $rw -column 2 -sticky e
    }
  }

  if {$::tcl_platform(platform) eq "windows"} {

    if $::advanced {
      # instopt_adjustpath
      incr rw
      pgrid [ttk::label .pathl -text [__ "Adjust searchpath"]] \
          -in $curf -row $rw -column 0 -columnspan 2 -sticky w
      ttk::checkbutton .pathb -variable ::vars(instopt_adjustpath)
      pgrid .pathb -in $curf -row $rw -column 2 -sticky e

      # tlpdbopt_desktop_integration
      set ::desk_int \
          [list [__ "No shortcuts"] [__ "TeX Live menu"] [__ "Launcher entry"]]
      incr rw
      pgrid [ttk::label .dkintl -text [__ "Desktop integration"]] \
          -in $curf -row $rw -column 0 -sticky w
      pgrid [ttk::combobox .dkintb -values $::desk_int -state readonly \
                 -width 20] \
          -in $curf -row $rw -column 1 -columnspan 2 -sticky e
      var2combo "tlpdbopt_desktop_integration" .dkintb
      bind .dkintb <<ComboboxSelected>> \
          {+combo2var .dkintb "tlpdbopt_desktop_integration"}

      # tlpdbopt_file_assocs
      set ::assoc [list [__ "None"] [__ "Only new"] [__ "All"]]
      incr rw
      pgrid [ttk::label .assocl -text [__ "File associations"]] \
          -in $curf -row $rw -column 0 -sticky w
      pgrid [ttk::combobox .assocb -values $::assoc -state readonly -width 12] \
          -in $curf -row $rw -column 1 -columnspan 2 -sticky e
      var2combo "tlpdbopt_file_assocs" .assocb
      bind .assocb <<ComboboxSelected>> \
          {+combo2var .assocb "tlpdbopt_file_assocs"}
    }

    # tlpdbopt_w32_multi_user
    incr rw
    pgrid [ttk::label .adminl -text [__ "Install for all users"]] \
        -in $curf -row $rw -column 0 -columnspan 2 -sticky w
    ttk::checkbutton .adminb -variable ::vars(tlpdbopt_w32_multi_user)
    pgrid .adminb -in $curf -row $rw -column 2 -sticky e
    if {!$::is_admin} {
      .adminb state disabled
      .adminl configure -foreground $::gry
    }

    # collection-texworks
    incr rw
    pgrid [ttk::label .texwl -text [__ "Install TeXworks front end"]] \
        -in $curf -row $rw -column 0 -columnspan 2 -sticky w
    ttk::checkbutton .texwb -variable ::vars(collection-texworks)
    .texwb configure -command \
        {set ::vars(selected_scheme) "scheme-custom"; update_vars; show_stats}
    pgrid .texwb -in $curf -row $rw -column 2 -sticky e
  } else {
    if $::advanced {
      # instopt_adjustpath, unix edition: symlinks
      # tlpdbopt_sys_[bin|info|man]
      incr rw
      pgrid [ttk::label .pathl \
                 -text [__ "Create symlinks in standard directories"]] \
          -in $curf -row $rw -column 0 -columnspan 2 -sticky w
      pgrid [ttk::checkbutton .pathb -variable ::vars(instopt_adjustpath)] \
          -in $curf -row $rw -column 2 -sticky e
      dis_enable_symlink_option; # enable only if standard directories ok
      incr rw
      pgrid [ttk::button .symspec -text [__ "Specify directories"] \
                 -command edit_symlinks] \
          -in $curf -row $rw -column 1 -columnspan 2 -sticky e
    }
  }

  if $::advanced {
    # spacer/filler
    incr rw
    pgrid [ttk::label .spaces -text " "] -in $curf -row $rw -column 0
    grid rowconfigure $curf $rw -weight 1
    # final entry: instopt_adjustrepo
    incr rw
    pgrid [ttk::label .ctanl -text \
               [__ "After install, set CTAN as source for package updates"]] \
        -in $curf -row $rw -column 0 -columnspan 2 -sticky w
    pgrid [ttk::checkbutton .ctanb -variable ::vars(instopt_adjustrepo)] \
      -in $curf -row $rw -column 2 -sticky e
  }

  if $::advanced {port_dis_or_activate 0}
  show_stats
  wm overrideredirect . 0
  wm resizable . 0 0
  update
  wm state . normal
  raise .
  if {$::tcl_platform(platform) eq "windows"} {wm deiconify .}
  if {[is_nonempty $::vars(TEXDIR)] && ! $::td_warned} {
    td_warn $::vars(TEXDIR)
  }
  #if [info exists ::env(dbgui)] {puts "dbgui: unsetting menu_ans"}
  unset -nocomplain ::menu_ans
  vwait ::menu_ans
  #if [info exists ::env(dbgui)] {puts "dbgui0: menu_ans is $::menu_ans"}
  return $::menu_ans
}; # run_menu

#############################################################

# we need data from the backend.
# choices of schemes, platforms and options impact choices of
# collections and required disk space.
# the vars array contains all this variable information.
# the calc_depends proc communicates with the backend to update this array.

proc read_descs {} {
  set l [read_line_no_eof]
  if {$l ne "descs"} {
    err_exit "'descs' expected but $l found"
  }
  while 1 {
    set l [read_line_no_eof]
    if [regexp {^([^:]+): (\S+) (.*)$} $l m p c d] {
      if {$c eq "Collection"} {
        set ::coll_descs($p) $d
      } elseif {$c eq "Scheme"} {
        set ::scheme_descs($p) $d
      }
    } elseif {$l eq "enddescs"} {
      break
    } else {
      err_exit "Illegal line $l in descs section"
    }
  }
  set ::scheme_descs(scheme-custom) [__ "Custom scheme"]
}

proc read_vars {} {
  set l [read_line_no_eof]
  if {$l ne "vars"} {
    err_exit "'vars' expected but $l found"
  }
  while 1 {
    set l [read_line_no_eof]
    if [regexp {^([^:]+): (.*)$} $l m k v] {
      set ::vars($k) $v
    } elseif {$l eq "endvars"} {
      break
    } else {
      err_exit "Illegal line $l in vars section"
    }
  }
  if {"total_size" ni [array names ::vars]} {
    set ::vars(total_size) 0
  }
}; # read_vars

proc write_vars {} {
  chan puts $::inst "vars"
  foreach v [array names ::vars] {chan puts $::inst "$v: $::vars($v)"}
  chan puts $::inst "endvars"
  chan flush $::inst
}

proc update_vars {} {
  chan puts $::inst "calc"
  write_vars
  read_vars
}

proc read_menu_data {} {
  # the expected order is: year, svn, descs, vars, schemes (one line), binaries
  # note. lindex returns an empty string if the index argument is too high.
  # empty lines result in an err_exit.

  # year; should be first line
  set l [read_line_no_eof]
  if [regexp {^year: (\S+)$} $l d y] {
    set ::release_year $y
  } else {
    err_exit "year expected but $l found"
  }

  # revision; should be second line
  set l [read_line_no_eof]
  if [regexp {^svn: (\S+)$} $l d y] {
    set ::svn $y
  } else {
    err_exit "revision expected but $l found"
  }

  # windows: admin status
  if {$::tcl_platform(platform) eq "windows"} {
    set l [read_line_no_eof]
    if [regexp {^admin: ([01])$} $l d a] {
      set ::is_admin $a
    } else {
      err_exit "admin: \[0|1\] expected but $l found"
    }
  }

  read_descs

  read_vars

  # schemes order (one line)
  set l [read_line_no_eof]
  if [regexp {^schemes_order: (.*)$} $l m sl] {
    set ::schemes_order $sl
  } else {
    err_exit "schemes_order expected but $l found"
  }
  if {"selected_scheme" ni [array names ::vars] || \
        $::vars(selected_scheme) ni $::schemes_order} {
    set ::vars(selected_scheme) [lindex $::schemes_order 0]
  }

  # binaries
  set l [read_line_no_eof]
  if {$l ne "binaries"} {
    err_exit "'binaries' expected but $l found"
  }
  while 1 {
    set l [read_line_no_eof]
    if [regexp {^([^:]+): (.*)$} $l m k v] {
      set ::bin_descs($k) $v
    } elseif {$l eq "endbinaries"} {
      break
    } else {
      err_exit "Illegal line $l in binaries section"
    }
  }

  set l [read_line_no_eof]
  if {$l ne "endmenudata"} {
    err_exit "'endmenudata' expected but $l found"
  }
}; # read_menu_data

proc answer_to_perl {} {
  # we just got a line "mess_yesno" from perl
  # finish reading the message text, put it in a message box
  # and write back the answer
  set mess {}
  while 1 {
    set ll [read_line]
    if {[lindex $ll 0] < 0} {
      err_exit "Error while reading from Perl backend"
    } else {
      set l [lindex $ll 1]
    }
    if  {$l eq "endmess"} {
      break
    } else {
      lappend mess $l
    }
  }
  set m [join $mess "\n"]
  set ans [tk_messageBox -type yesno -icon question -message $m]
  chan puts $::inst [expr {$ans eq yes ? "y" : "n"}]
  chan flush $::inst
}; # answer_to_perl

proc run_installer {} {
  set ::out_log {}
  show_log 1; # 1: with abort button
  .close state disabled
  chan puts $::inst "startinst"
  write_vars
  # the backend was already running and needs no further encouragement

  # switch to non-blocking i/o
  chan configure $::inst -buffering line -blocking 0
  chan event $::inst readable read_line_cb
  raise .
  if {$::tcl_platform(platform) eq "windows"} {wm deiconify .}
}; # run_installer

proc whataboutclose {} {
  if [winfo exists .abort] {
    # log window with abort
    .abort invoke
  } elseif [winfo exists .log] {
    # log window without abort
    .close invoke
  } elseif [winfo exists .quit] {
    # menu window
    .quit invoke
  }
  # no action for close button of splash screen
}

proc main_prog {} {

  wm protocol . WM_DELETE_WINDOW whataboutclose

  # handle some command-line arguments.
  # the argument list should already be normalized: '--' => '-', "=" => ' '
  set ::prelocation "..."
  set ::mir_selected 1 ; # i.e. default or set by parameter
  set l [llength $::argv]
  set i $l
  while {$i > 0} {
    set iplus $i
    incr i -1
    set p [lindex $::argv $i]
    if {$p in {"-location" "-url" "-repository" "-repos" "-repo"}} {
      # check for repository argument: bail out if obviously invalid
      if {$iplus<$l} {
        set p [lindex $::argv $iplus]
        if {$p ne "ctan" && ! [possible_repository $p]} {
          err_exit [__ "%s not a local or remote repository" $p]
        }
        set ::prelocation $p
      } else {
        err_exit [__ "%s requires an argument" $p]
      }
    } elseif {$p eq "-select-repository"} {
      # in this case, we start with selecting a repository
      # from a mirror list and modify ::argv to take the selection
      # into account before contacting the perl back end.
      unset -nocomplain ::mir_selected
      # remove this argument
      set ::argv [lreplace $::argv $i $i]
    }
  }
  unset i

  pre_splash
  if {! [info exists ::mir_selected]} {
    select_mirror
    # waits for ::mir_selected
  }
  make_splash

  # start install-tl-[tcl] via a pipe.
  set cmd [list "|${::perlbin}" "${::instroot}/install-tl" \
               "-from_ext_gui" {*}$::argv "2>@1"]
  if [catch {open $cmd r+} ::inst] {
    err_exit "Error starting Perl backend"
  }

  show_time "opened pipe"
  set ::perlpid [pid $::inst]

  # for windows < 10: make sure the main window is still on top
  raise .

  chan configure $::inst -buffering line -blocking 1

  # possible input from perl until the menu starts:
  # - question about prior canceled installation
  # - location (actual repository)
  # - menu data
  set answer ""
  unset -nocomplain ::loaded
  while 1 { ; # initial perl output
    set ll [read_line]
    if {[lindex $ll 0] < 0} {
      break
    }
    set l [lindex $ll 1]
    # There may be occasion for a dialog
    if {$l eq "mess_yesno"} {
      answer_to_perl
    } elseif [string match "location: ?*" $l] {
      # this one comes straight from install-tl, rather than
      # from install-tl-extl.pl
      # installer about to contact repository, which may
      # fail and cause an indefinite delay
      chan configure $::inst -blocking 0
      chan event $::inst readable read_line_loading
      if [winfo exists .loading] {
        .loading configure -text [__ "Trying to load %s.

If this takes too long, press Abort or choose another repository." \
                                      [string range $l 10 end]]
        update
      }
      break
    }
  }
  # waiting till the repository has been loaded
  vwait ::loaded
  unset ::loaded
  # resume reading from back end in blocking mode
  while 1 {
    set ll [read_line]
    if {[lindex $ll 0] < 0} {
      break
    }
    set l [lindex $ll 1]
    if {$l eq "menudata"} {
      # so we do want a menu and expect menu data,
      # parsing which may take a while
      read_menu_data
      show_time "read menu data from perl"
      set ::advanced 0
      set ::alltrees 0
      set answer [run_menu]
      #if [info exists ::env(dbgui)] {puts "dbgui1: menu_ans is $::menu_ans"}
      if {$answer eq "advanced"} {
        # this could only happen if $::advanced was 0
        set ::advanced 1
        #if [info exists ::env(dbgui)] {puts "dbgui: Setting advanced to 1"}
        set answer [run_menu]
        if {$answer eq "alltrees"} {
          set ::alltrees 1
          #if [info exists ::env(dbgui)] {puts "dbgui: Setting alltrees to 1"}
          set answer [run_menu]
        }
      }
      break
    } elseif {$l eq "startinst"} {
      # use an existing profile:
      set ::out_log {}
      set answer "startinst"
      break
    } else {
      lappend ::out_log $l
    }
  }
  if {$answer eq "startinst"} {
  # disable browser-style keyboard shortcuts for scaling
    bind . <Control-KeyRelease-minus> {}
    bind . <Control-KeyRelease-equal> {}
    bind . <Control-Shift-KeyRelease-equal> {}
    bind . <Control-KeyRelease-plus> {}
    bind . <Control-KeyRelease-0> {}
    if {$::tcl_platform(os) eq "Darwin"} {
      bind . <Command-KeyRelease-minus> {}
      bind . <Command-KeyRelease-equal> {}
      bind . <Command-Shift-KeyRelease-equal> {}
      bind . <Command-KeyRelease-plus> {}
      bind . <Command-KeyRelease-0> {}
    }

    run_installer
    # invokes show_log which first destroys previous children
  } else {
    log_exit
  }
}; # main_prog

#file delete $::dblfile

main_prog
