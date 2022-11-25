#!/usr/bin/env nu

def print-out [-t, name, value] {
  print $'DEBUG: ($name) is:'
  print $value
  if $t { exit 0 }
}

let agent = "Mozilla/5.0 (X11; Linux x86_64; rv:99.0) Gecko/20100101 Firefox/100.0"
let base_url = "https://animixplay.to"
let gogohd_url = "https://gogohd.net"
let quality = "best"
let player_fn = (
  if $nu.os-info.name == linux {
    "mpv"
  } else "iina"
)

def parse-url-query [query: string] {
  $query
  | split row '&'
  | each {|it| $it | parse "{key}={value}" }
  | flatten
  | rotate
  | drop column 1
  | headers
  | get 0
}

def episode_list [anime: record] {
  let response = (curl -A $agent -s $'($base_url)/v1/($anime.path)')
  # print $response
  echo $response
  | query web -q '#epslistplace'
  | get 0
  | str replace 'extra' ''
  | str replace 'PV' ''
  | from json
}

def 'query gogo' [query: string] {
  let response = (fetch $'https://gogoanime.dk/search.html?keyword=($query)')
  let release = ($response | query web -q '.items li .released' | str trim  | parse 'Released: {year}')
  let path = ($response | query web -m -a href -q '.items li .name a' | wrap path)
  let title = ($response | query web -m -a title -q '.items li .name a' | wrap title)
  let image = ($response | query web -m -a src -q '.items li img' | wrap image)
  $release | merge $path | merge $title | merge $image
}

# def search_anime [query: string] {
#   let search = ($query | str replace ' ' '-')
#   let url = $"https://gogoanime.dk/search.html?keyword=($search)"
#   fetch $url
#   | query web -a href -q 'ul a'
#   | where $it =~ /category
#   | each { |it|
#       basename $it | str trim
#   }
# }

def search_anime [query: string] {
  let search = ($query | str replace ' ' '-')
  query gogo $search
  | each { |it|
    $it | update path ($it.path | path basename)
  }
}

def get_video_quality_m3u8 [links, dpage_url] {
  if $links =~ manifest { $links } else {
    let m3u8_links = (curl -s -A $agent --referer $dpage_url $links | str trim -r | lines)
    let m3u8_info = {
      header: ($m3u8_links | get 0),
      body: (
        $m3u8_links
        | skip
        | group 2
        | each { |it|
            $it.0
            | parse '#EXT-X-STREAM-INF:PROGRAM-ID={id},BANDWIDTH={bandwidth},RESOLUTION={width}x{height},FRAME-RATE={framerate},CODECS="{codecs}"'
            | update height ($in.height | into int | get 0)
            | update width ($in.width | into int | get 0)
            | update codecs ($in.codecs | split row ',')
            | insert url $it.1
        }
        | flatten
        | sort-by -r width
      )
    }
    let res_selector = (
      if $quality == best {
        $m3u8_info.body | first
      } else if $quality == worst {
        $m3u8_info.body | last
      } else {
        let tmp = ($m3u8_info.body | where width == $quality)
        if ($tmp | length | $in == 0) {
          print "Current video quality is not available (defaulting to best quality)"
          $m3u8_info.body | first
        } else $tmp
      }
    )
    $res_selector.url
  }
}

# FIXME haven't tested this yet
def get_video_quality_mp4 [links] {
  print-out -t 'links' $links
  if ($quality == best) or ($quality == worst) {
    $links | tail -n 1 | cut -d '>' -f 2
  } else {
    let video_url = ($links | grep -i $"($quality)p" | head -n 1 | cut -d '>' -f 2)
    if ($video_url | str length | $in == 0) {
      print "Current video quality is not available (defaulting to best quality)"
      $links | tail -n 1 | cut -d '>' -f 2
    } else $video_url
  }
}

def get_video_link [dpage_url] {
  let id = ($dpage_url | url query | parse-url-query $in | get id)
  let response = (
    curl -sL -A $agent $"($gogohd_url)/streaming.php?id=($id)"
    | sed -nE -e 's/.*class="container-(.*)">/\1/p' -e 's/.*class="wrapper container-(.*)">/\1/p' -e 's/.*class=".*videocontent-(.*)">/\1/p' -e 's/.*data-value="(.*)">.*/\1/p' -e 's/.*data-status="1".*data-video="(.*)">.*/\1/p'
  )
  let provider = 1
  let provider_name = 'Animixplay'
  print $"Fetching ($provider_name) Direct link.."
  let refr = $base_url
  let enc_id = ($id | encode base64 | str trim -r -c '=')
  let ani_id = ($"($id)LTXs3GrU8we9O($enc_id)" | encode base64 | str trim -r -c '=')
  let result_links = (curl -Is -A $agent $"($base_url)/api/cW9($ani_id)" | sed -nE 's_[L|l]ocation: https?://[^#]*#([^#]*).*_\1_p' | decode base64)
  if $result_links =~ m3u8 {
    get_video_quality_m3u8 $result_links $dpage_url
  } else {
    get_video_quality_mp4 $result_links
  }
}

def open_episode [anime: record, selected_episode, episode_paths] {
  print $'Loading episode ($selected_episode)'
  let dpage_link = ($episode_paths | get $selected_episode | 'https:' + $in)
  if ($dpage_link | str length | $in == 0) {
    print "Episode doesn't exist!"
    exit
  }
  print $'Scraping "($dpage_link)" for video'
  let video_url = (get_video_link $dpage_link)
  if ($video_url | str length | $in == 0) {
    print "Video URL not found"
    exit
  }
  print "Currently playing $trackma_title ($provider_name)"
  mpv $'--force-media-title=($anime.title) ep ($selected_episode + 1)' $video_url
}

# Abstraction over read
# nushell doesn't have a read like bash. This read program reads a
# string of characters until a new line and echoes the string without
# the terminating newline
def read-line [] {
  read | str trim
}

# anime.nu v0.0.1 by goiabae
def main [] {
  if (version).version != '0.71.0' {
    print 'This script was tested with nushell version 0.71.0.'
    print 'You may run into issues or crashes when running on a different version'
  }

  print 'Search Anime'
  print -n '> '
  let query = (read-line)
  print $'Searching query "($query)"'

  let results = (search_anime $query)
  if ($results | length | $in == 0) {
    print 'No search results found'
    exit
  }

  print "Query Results:"
  echo $results
  print -n 'Select index [NUMBER]: '
  let selection = (read-line | into int)

  let episodes = (echo $results | get $selection | episode_list $in | reject eptotal | rotate | get column0)

  print -n $'Select index [1-($episodes | length)]: '
  let selected_ep = (read-line | into int)

  open_episode ($results | get $selection) $selected_ep $episodes
}
