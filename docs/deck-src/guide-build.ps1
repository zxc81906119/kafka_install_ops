# Manual overview deck, step 2 of 2: fills the company template in PowerPoint from guide.json (made by guide.js).
#   powershell -ExecutionPolicy Bypass -File guide-build.ps1 -Template <template.pptx> -BuildDir <dir> -Out <deck.pptx> [-Images]
# -Images also exports every slide as a PNG into <dir>\slides for checking the layout.
# Prints a line for every text box that runs past the content area. ASCII only: PowerShell 5.1 reads scripts as ANSI.
param(
  [Parameter(Mandatory = $true)][string]$Template,
  [Parameter(Mandatory = $true)][string]$BuildDir,
  [Parameter(Mandatory = $true)][string]$Out,
  [switch]$Images
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# Template geometry in points (slide 960 x 540): the layouts' content placeholder
$LEFT = 39; $TOP = 113; $WIDTH = 873; $BOTTOM = 505
$GAP = 14
$FONT = "Microsoft JhengHei"
$FOOTER = -join ([char[]](0x667A,0x6167,0x8CA1,0x7522,0x6B0A,0x5C6C,0x8CC7,0x62D3,0x5B8F,0x5B87,0x570B,0x969B,0x28,0x80A1,0x29,0x516C,0x53F8,0xFF0C,0x8907,0x88FD,0x6216,0x8F49,0x8F09,0x5FC5,0x7A76))

# PowerPoint colors are BGR integers
function Rgb([string]$hex) {
  $r = [Convert]::ToInt32($hex.Substring(0, 2), 16)
  $g = [Convert]::ToInt32($hex.Substring(2, 2), 16)
  $b = [Convert]::ToInt32($hex.Substring(4, 2), 16)
  return $r + 256 * $g + 65536 * $b
}
$INK = Rgb "1F2937"
$BODY = Rgb "374151"
$SOFT = Rgb "F3F5F8"
$LINE = Rgb "D9DEE7"
$WHITE = Rgb "FFFFFF"

# Fill a placeholder by its type (1 title, 2 body text); remove it when there is no text
function SetPlaceholder($slide, [int]$type, [string]$text) {
  foreach ($shape in @($slide.Shapes)) {
    if ($shape.Type -eq 14 -and $shape.PlaceholderFormat.Type -eq $type) {
      if ($text) {
        $shape.TextFrame.TextRange.Text = $text
      } else {
        $shape.Delete()
      }
      return
    }
  }
}

# The big content placeholder (type 7) is replaced by our picture and shapes
function RemoveContentPlaceholders($slide) {
  foreach ($shape in @($slide.Shapes)) {
    if ($shape.Type -eq 14 -and $shape.PlaceholderFormat.Type -eq 7) {
      $shape.Delete()
    }
  }
}

function AddFooter($slide) {
  $slide.HeadersFooters.Footer.Visible = -1
  $slide.HeadersFooters.Footer.Text = $FOOTER
  $slide.HeadersFooters.SlideNumber.Visible = -1
}

function NewText($slide, $x, $y, $w, $h, [string]$text, [int]$size, [int]$color, [bool]$bold, [string]$name) {
  $box = $slide.Shapes.AddTextbox(1, $x, $y, $w, $h)
  $box.Name = $name
  $frame = $box.TextFrame
  $frame.WordWrap = -1
  $frame.AutoSize = 0
  $frame.MarginLeft = 0; $frame.MarginRight = 0; $frame.MarginTop = 0; $frame.MarginBottom = 0
  $frame.TextRange.Text = $text
  $frame.TextRange.Font.Size = $size
  $frame.TextRange.Font.Color.RGB = $color
  $frame.TextRange.Font.Bold = $(if ($bold) { -1 } else { 0 })
  $frame.TextRange.Font.Name = $FONT
  $frame.TextRange.Font.NameFarEast = $FONT
  $box.Height = [single]$h
  return $box
}

# A soft rounded card: bold colored label, then the body text. Returns the height it needs.
function NewCard($slide, $x, $y, $w, $h, $block, [int]$color, [int]$index) {
  $card = $slide.Shapes.AddShape(5, $x, $y, $w, $h)
  $card.Name = "Card $index"
  $card.Adjustments.Item(1) = 0.05
  $card.Fill.ForeColor.RGB = $SOFT
  $card.Line.Visible = 0
  $card.Shadow.Visible = 0
  $frame = $card.TextFrame
  $frame.WordWrap = -1
  $frame.AutoSize = 0
  $frame.MarginLeft = 10; $frame.MarginRight = 10; $frame.MarginTop = 8; $frame.MarginBottom = 8
  $frame.VerticalAnchor = 1
  $frame.TextRange.Text = $block[0] + "`r" + $block[1]
  $frame.TextRange.ParagraphFormat.Alignment = 1
  $frame.TextRange.Font.Name = $FONT
  $frame.TextRange.Font.NameFarEast = $FONT
  $frame.TextRange.Font.Size = 14
  $frame.TextRange.Font.Color.RGB = $BODY
  $frame.TextRange.Paragraphs(1).Font.Bold = -1
  $frame.TextRange.Paragraphs(1).Font.Color.RGB = $color
  $frame.TextRange.Paragraphs(1).ParagraphFormat.SpaceAfter = 3
  $frame.TextRange.Paragraphs(2).Font.Bold = 0
  return $card
}

function CardNeededHeight($card) {
  return [double]$card.TextFrame.TextRange.BoundHeight + 18
}

function Warn([int]$number, [string]$what) {
  Write-Output "OVERFLOW slide ${number}: $what"
}

# Cards stacked in a column; returns the bottom of the stack
function StackCards($slide, $x, $y, $w, $blocks, [int]$color, [int]$number) {
  $at = $y
  $i = 0
  foreach ($block in $blocks) {
    $i++
    $card = NewCard $slide $x $at $w 60 $block $color $i
    $needed = CardNeededHeight $card
    $card.Height = [single]$needed
    $at = $at + $needed + 10
  }
  if (($at - 10) -gt $BOTTOM) {
    Warn $number ("cards end at " + [int]($at - 10))
  }
  return ($at - 10)
}

# Cards side by side in a row of the given height
function RowCards($slide, $y, $h, $blocks, [int]$color, [int]$number) {
  $count = $blocks.Count
  $w = ($WIDTH - ($count - 1) * $GAP) / $count
  $i = 0
  foreach ($block in $blocks) {
    $card = NewCard $slide ($LEFT + $i * ($w + $GAP)) $y $w $h $block $color ($i + 1)
    $needed = CardNeededHeight $card
    if ($needed -gt $h) {
      Warn $number ("card '" + $i + "' needs " + [int]$needed + " of " + [int]$h)
    }
    $i++
  }
}

# FitRowHeight: the height a row of cards needs for its text (cards are measured, then removed); at least 52
function FitRowHeight($slide, $blocks, [int]$color) {
  $count = $blocks.Count
  $w = ($WIDTH - ($count - 1) * $GAP) / $count
  $needed = 52
  $i = 0
  foreach ($block in $blocks) {
    $card = NewCard $slide ($LEFT + $i * ($w + $GAP)) 0 $w 112 $block $color ($i + 1)
    $h = CardNeededHeight $card
    if ($h -gt $needed) {
      $needed = $h
    }
    $card.Delete()
    $i++
  }
  return [Math]::Ceiling($needed)
}

function AddPicture($slide, [string]$file, $x, $y, $w, $h, [string]$alt) {
  $picture = $slide.Shapes.AddPicture((Join-Path $BuildDir $file), 0, -1, $x, $y, $w, $h)
  $picture.AlternativeText = $alt
  return $picture
}

function FillDiagram($slide, $item, [int]$color, [int]$number) {
  $blocks = @($item.blocks)
  $height = $BOTTOM - $TOP

  if ($item.compact -and ($blocks.Count -eq 0)) {
    # No cards: the picture takes the whole content area
    $pictureWidth = [Math]::Min($WIDTH, $height * $item.ratio)
    $pictureHeight = $pictureWidth / $item.ratio
    [void](AddPicture $slide $item.file ($LEFT + ($WIDTH - $pictureWidth) / 2) ($TOP + ($height - $pictureHeight) / 2) $pictureWidth $pictureHeight $item.title)
    return
  }

  if ($item.ratio -ge 2.2) {
    # Wide picture on top, cards below (compact slides: the card row is only as tall as its text)
    $cardHeight = 112
    if ($item.compact) {
      $cardHeight = FitRowHeight $slide $blocks $color
    }
    $maxHeight = $height - $cardHeight - $GAP
    if ($blocks.Count -eq 0) {
      $maxHeight = $height
    }
    $pictureWidth = [Math]::Min($WIDTH, $maxHeight * $item.ratio)
    $pictureHeight = $pictureWidth / $item.ratio
    [void](AddPicture $slide $item.file ($LEFT + ($WIDTH - $pictureWidth) / 2) ($TOP + ($maxHeight - $pictureHeight) / 2) $pictureWidth $pictureHeight $item.title)
    if ($blocks.Count -gt 0) {
      RowCards $slide ($BOTTOM - $cardHeight) $cardHeight $blocks $color $number
    }
  } else {
    # Cards on the left, picture on the right
    $cardWidth = 262
    $pictureWidth = $WIDTH - $cardWidth - $GAP
    $pictureHeight = $pictureWidth / $item.ratio
    if ($pictureHeight -gt $height) {
      $pictureHeight = $height
      $pictureWidth = $pictureHeight * $item.ratio
    }
    [void](StackCards $slide $LEFT $TOP $cardWidth $blocks $color $number)
    $x = $LEFT + $cardWidth + $GAP + ($WIDTH - $cardWidth - $GAP - $pictureWidth) / 2
    [void](AddPicture $slide $item.file $x ($TOP + ($height - $pictureHeight) / 2) $pictureWidth $pictureHeight $item.title)
  }
}

function FillFlow($slide, $item, [int]$color, [int]$number) {
  $steps = @($item.flow)
  $count = $steps.Count
  $arrow = 34
  $w = ($WIDTH - ($count - 1) * $arrow) / $count
  $y = $TOP + 32
  $i = 0
  foreach ($step in $steps) {
    $x = $LEFT + $i * ($w + $arrow)
    [void](AddPicture $slide $step.icon ($x + ($w - 64) / 2) $y 64 64 $step.head)
    $head = NewText $slide $x ($y + 74) $w 26 $step.head 18 $INK $true "Step $($i + 1)"
    $head.TextFrame.TextRange.ParagraphFormat.Alignment = 2
    $sub = NewText $slide $x ($y + 104) $w 46 $step.sub 14 $BODY $false "Step $($i + 1) detail"
    $sub.TextFrame.TextRange.ParagraphFormat.Alignment = 2
    if ($i -lt ($count - 1)) {
      $line = $slide.Shapes.AddLine(($x + $w + 4), ($y + 32), ($x + $w + $arrow - 4), ($y + 32))
      $line.Name = "Arrow $($i + 1)"
      $line.Line.ForeColor.RGB = $color
      $line.Line.Weight = 2.25
      $line.Line.EndArrowheadStyle = 2
    }
    $i++
  }
  RowCards $slide ($BOTTOM - 112) 112 @($item.blocks) $color $number
}

function FillTiles($slide, $item, [int]$color, [int]$number) {
  $tiles = @($item.tiles)
  $count = $tiles.Count
  $w = ($WIDTH - ($count - 1) * $GAP) / $count
  $i = 0
  foreach ($tile in $tiles) {
    $x = $LEFT + $i * ($w + $GAP)
    [void](AddPicture $slide $tile.icon ($x + ($w - 56) / 2) ($TOP + 32) 56 56 $tile.head)
    $head = NewText $slide $x ($TOP + 96) $w 34 $tile.head 24 $color $true "Tile $($i + 1)"
    $head.TextFrame.TextRange.ParagraphFormat.Alignment = 2
    $sub = NewText $slide ($x + 6) ($TOP + 132) ($w - 12) 46 $tile.sub 14 $BODY $false "Tile $($i + 1) detail"
    $sub.TextFrame.TextRange.ParagraphFormat.Alignment = 2
    $i++
  }
  RowCards $slide ($BOTTOM - 112) 112 @($item.blocks) $color $number
}

function FillTable($slide, $item, [int]$color, [int]$number) {
  $table = $item.table
  $rows = @($table.rows)
  $columns = @($table.head).Count
  $blocks = @($item.blocks)
  $rowHeight = 36
  $fontSize = 14
  # compact slides: small tables (up to 6 rows with the header) get taller rows and a larger font
  if ($item.compact -and ($blocks.Count -eq 0) -and (($rows.Count + 1) -le 6)) {
    $rowHeight = [Math]::Min(60, [Math]::Floor(($BOTTOM - $TOP) / ($rows.Count + 1)))
    $fontSize = 16
  }
  $shape = $slide.Shapes.AddTable($rows.Count + 1, $columns, $LEFT, $TOP, $WIDTH, $rowHeight * ($rows.Count + 1))
  $shape.Name = "Table"
  for ($c = 1; $c -le $columns; $c++) {
    $shape.Table.Columns($c).Width = [single]($WIDTH * $table.widths[$c - 1])
  }
  for ($r = 1; $r -le ($rows.Count + 1); $r++) {
    for ($c = 1; $c -le $columns; $c++) {
      $cell = $shape.Table.Cell($r, $c)
      if ($r -eq 1) { $text = $table.head[$c - 1] } else { $text = $rows[$r - 2][$c - 1] }
      $range = $cell.Shape.TextFrame.TextRange
      $range.Text = $text
      $range.Font.Name = $FONT
      $range.Font.NameFarEast = $FONT
      $range.Font.Size = $fontSize
      $cell.Shape.TextFrame.VerticalAnchor = 3
      if ($r -eq 1) {
        $range.Font.Bold = -1
        $range.Font.Color.RGB = $WHITE
        $cell.Shape.Fill.ForeColor.RGB = $color
      } else {
        $range.Font.Bold = 0
        $range.Font.Color.RGB = $BODY
        if (($r % 2) -eq 0) { $cell.Shape.Fill.ForeColor.RGB = $WHITE } else { $cell.Shape.Fill.ForeColor.RGB = $SOFT }
      }
    }
  }
  $tableBottom = $shape.Top + $shape.Height
  if ($blocks.Count -gt 0) {
    RowCards $slide ($tableBottom + $GAP) ([Math]::Min(120, $BOTTOM - $tableBottom - $GAP)) $blocks $color $number
  } elseif ($tableBottom -gt $BOTTOM) {
    Warn $number ("table ends at " + [int]$tableBottom)
  }
}

# Configuration excerpt: file name and a dark monospace box on the left, cards on the right (full width when there are no cards)
function FillCode($slide, $item, [int]$color, [int]$number) {
  $blocks = @($item.blocks)
  $codeWidth = 560
  if ($blocks.Count -eq 0) {
    $codeWidth = $WIDTH
  }
  $caption = NewText $slide $LEFT $TOP $codeWidth 18 $item.codeFile 12 $BODY $true "File"
  $boxTop = $TOP + 24
  $box = $slide.Shapes.AddShape(5, $LEFT, $boxTop, $codeWidth, ($BOTTOM - $boxTop))
  $box.Name = "Code"
  $box.Adjustments.Item(1) = 0.02
  $box.Fill.ForeColor.RGB = $INK
  $box.Line.Visible = 0
  $box.Shadow.Visible = 0
  $frame = $box.TextFrame
  $frame.WordWrap = 0
  $frame.AutoSize = 0
  $frame.MarginLeft = 14; $frame.MarginRight = 10; $frame.MarginTop = 10; $frame.MarginBottom = 10
  $frame.VerticalAnchor = 1
  $frame.TextRange.Text = ($item.code -replace "`n", "`r")
  $frame.TextRange.ParagraphFormat.Alignment = 1
  $frame.TextRange.ParagraphFormat.SpaceWithin = 1.0
  $frame.TextRange.Font.Name = "Consolas"
  $frame.TextRange.Font.NameFarEast = $FONT
  $frame.TextRange.Font.Size = $(if ($blocks.Count -eq 0) { 10 } else { 11 })
  $frame.TextRange.Font.Bold = 0
  $frame.TextRange.Font.Color.RGB = (Rgb "E5E7EB")
  if (([double]$frame.TextRange.BoundHeight + 20) -gt ($BOTTOM - $boxTop)) {
    Warn $number ("code needs " + [int]([double]$frame.TextRange.BoundHeight + 20) + " of " + [int]($BOTTOM - $boxTop))
  }
  if (([double]$frame.TextRange.BoundWidth + 24) -gt $codeWidth) {
    Warn $number ("code is " + [int]([double]$frame.TextRange.BoundWidth + 24) + " wide of " + $codeWidth)
  }
  if ($blocks.Count -gt 0) {
    $x = $LEFT + $codeWidth + $GAP
    [void](StackCards $slide $x $TOP ($WIDTH - $codeWidth - $GAP) $blocks $color $number)
  }
}

function FillContents($slide, $item) {
  $rows = @($item.rows)
  $heights = @(178, 108, 72)
  $y = $TOP
  $i = 0
  foreach ($row in $rows) {
    $h = $heights[$i]
    $color = Rgb $row.color
    $badge = $slide.Shapes.AddShape(5, $LEFT, $y, 190, $h)
    $badge.Name = "Part $($i + 1)"
    $badge.Adjustments.Item(1) = 0.06
    $badge.Fill.ForeColor.RGB = $color
    $badge.Line.Visible = 0
    $frame = $badge.TextFrame
    $frame.WordWrap = -1
    $frame.VerticalAnchor = 3
    $frame.TextRange.Text = $row.name + "`r" + $row.range + "`r" + $row.desc
    $frame.TextRange.ParagraphFormat.Alignment = 1
    $frame.TextRange.Font.Name = $FONT
    $frame.TextRange.Font.NameFarEast = $FONT
    $frame.TextRange.Font.Color.RGB = $WHITE
    $frame.TextRange.Font.Size = 14
    $frame.TextRange.Paragraphs(1).Font.Size = 20
    $frame.TextRange.Paragraphs(1).Font.Bold = -1
    $list = $slide.Shapes.AddShape(5, ($LEFT + 200), $y, ($WIDTH - 200), $h)
    $list.Name = "Part $($i + 1) chapters"
    $list.Adjustments.Item(1) = 0.06
    $list.Fill.ForeColor.RGB = $SOFT
    $list.Line.Visible = 0
    $frame = $list.TextFrame
    $frame.WordWrap = -1
    $frame.VerticalAnchor = 3
    $frame.MarginLeft = 14; $frame.MarginRight = 14
    $frame.TextRange.Text = $row.items
    $frame.TextRange.ParagraphFormat.Alignment = 1
    $frame.TextRange.ParagraphFormat.SpaceWithin = 1.15
    $frame.TextRange.Font.Name = $FONT
    $frame.TextRange.Font.NameFarEast = $FONT
    $frame.TextRange.Font.Size = 14
    $frame.TextRange.Font.Color.RGB = $BODY
    $y = $y + $h + 10
    $i++
  }
  [void](NewText $slide $LEFT $y $WIDTH 22 $item.foot 12 $BODY $false "Note")
}

$data = Get-Content -Raw -Encoding UTF8 (Join-Path $BuildDir "guide.json") | ConvertFrom-Json
$BuildDir = (Resolve-Path $BuildDir).Path
$Out = [IO.Path]::GetFullPath($Out)
$working = Join-Path $BuildDir "template-copy.pptx"
Copy-Item -LiteralPath $Template -Destination $working -Force

$powerpoint = New-Object -ComObject PowerPoint.Application
$deck = $powerpoint.Presentations.Open($working, 0, 0, 0)
try {
  while ($deck.Slides.Count -gt 0) {
    $deck.Slides.Item(1).Delete()
  }

  # Layouts in template order: cover, outline, divider, content, two contents, content without logo, back cover
  $master = $deck.Designs.Item(1).SlideMaster
  $COVER = $master.CustomLayouts.Item(1)
  $OUTLINE = $master.CustomLayouts.Item(2)
  $DIVIDER = $master.CustomLayouts.Item(3)
  $CONTENT = $master.CustomLayouts.Item(4)
  $BACK = $master.CustomLayouts.Item(7)

  $number = 0
  foreach ($item in $data.slides) {
    $number++
    switch ($item.kind) {
      "cover" {
        $slide = $deck.Slides.AddSlide($number, $COVER)
        SetPlaceholder $slide 1 $item.title
        SetPlaceholder $slide 2 $item.sub
      }
      "end" {
        $slide = $deck.Slides.AddSlide($number, $BACK)
        SetPlaceholder $slide 1 $item.title
        SetPlaceholder $slide 2 $item.sub
      }
      "outline" {
        $slide = $deck.Slides.AddSlide($number, $OUTLINE)
        SetPlaceholder $slide 1 $item.title
        foreach ($shape in @($slide.Shapes)) {
          if ($shape.Type -eq 14 -and $shape.PlaceholderFormat.Type -eq 7) {
            $shape.TextFrame.TextRange.Text = ($item.items -join "`r")
          }
        }
        AddFooter $slide
      }
      "divider" {
        $slide = $deck.Slides.AddSlide($number, $DIVIDER)
        SetPlaceholder $slide 1 $item.title
        SetPlaceholder $slide 2 ($item.sub -replace "`n", "`r")
        AddFooter $slide
      }
      default {
        $slide = $deck.Slides.AddSlide($number, $CONTENT)
        SetPlaceholder $slide 1 $item.title
        SetPlaceholder $slide 2 $item.tag
        RemoveContentPlaceholders $slide
        $color = Rgb $item.color
        if ($item.kind -eq "contents") {
          FillContents $slide $item
        } elseif ($item.file) {
          FillDiagram $slide $item $color $number
        } elseif ($item.code) {
          FillCode $slide $item $color $number
        } elseif ($item.table) {
          FillTable $slide $item $color $number
        } elseif ($item.flow) {
          FillFlow $slide $item $color $number
        } elseif ($item.tiles) {
          FillTiles $slide $item $color $number
        }
        AddFooter $slide
        if ($item.notes) {
          $slide.NotesPage.Shapes.Placeholders.Item(2).TextFrame.TextRange.Text = $item.notes
        }
      }
    }
  }

  $deck.SaveCopyAs($Out)
  if ($Images) {
    $imageDir = Join-Path $BuildDir "slides"
    [void](New-Item -ItemType Directory -Force -Path $imageDir)
    Get-ChildItem $imageDir -Filter *.png | Remove-Item
    for ($i = 1; $i -le $deck.Slides.Count; $i++) {
      $deck.Slides.Item($i).Export((Join-Path $imageDir ("s{0:D2}.png" -f $i)), "PNG", 1280, 720)
    }
  }
  Write-Output "wrote $($deck.Slides.Count) slides"
} catch {
  Write-Output "FAILED at slide $number, line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
  Write-Output $_.InvocationInfo.Line
  exit 1
} finally {
  $deck.Close()
  $powerpoint.Quit()
}
