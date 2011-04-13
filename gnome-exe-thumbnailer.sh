#!/bin/bash
shopt -s nocasematch

TEMPFILE1=$(mktemp)
TEMPFILE2=$(mktemp)
TEMPTHUMB=$(mktemp)

INPUTFILE="$1"
OUTPUTFILE="$2"

# Get the current icon theme (or override it by 3rd parameter):
THEME="${3:-$(gconftool-2 --get /desktop/gnome/interface/icon_theme)}"

case "$THEME" in
	Faenza*)
		THEME='faenza'
		DRAW='roundRectangle 2,2 45,45 3,3'
	;;
	
	elementary*|Ubuntu-Mono*|Humanity*)
		THEME='elementary'
		DRAW='roundRectangle 2,2 45,45 3,3'
	;;

	gnome|Human)
		THEME='gnome'
		DRAW='roundRectangle 2,2 45,45 4,4'
	;;

	Breathe)
		THEME='breathe'
		DRAW='roundRectangle 1,2 46,45 2,2'
	;;
	
	Tango*|*)
		THEME='tango'
		DRAW='roundRectangle 2,2 45,45 4,4'
	;;

esac


if [[ ${INPUTFILE##*.} = 'msi' ]]
then
	# Use generic installer icon for a .msi package:
	ICON=/usr/share/pixmaps/gnome-exe-thumbnailer/$THEME/installer.png
	TUNE='-modulate 120,100,0'

else
	# Extract group_icon resource.
	# If we get the "wrestool: $INPUTFILE could not find `1' in `group_icon' resource." error,
	# there is a 99.9% chance that input file is an installer.

	# Warning: Some redirection magic ahead.

	wrestool --extract --type=group_icon "$INPUTFILE" 2>&1 >$TEMPFILE1 | grep 'could not find'

	if [ $? -eq 0 ]
	then
		# Use generic installer icon:
		ICON=/usr/share/pixmaps/gnome-exe-thumbnailer/$THEME/installer.png
		TUNE='-modulate 120'

	else
		# Process extracted data, if we have some:
		if [ -s $TEMPFILE1 ]
		then
			# Look for the best usable icon:
			read OFFSET INDEX < <(
				icotool --list $TEMPFILE1 | awk '{
					ci=int(substr($2,index($2,"=") + 1));
					cw=int(substr($3,index($3,"=") + 1));
					cb=int(substr($5,index($5,"=") + 1));

					if ((cw > w && cw <= 32) || (cw == w && cb > b)) {
						b = cb;
						w = cw;
						i = ci;
					}
				}
				END {
					print (32 - w) / 2, i;
				}'
			)

			# Use a resized 48x48 icon if 32x32 or smaller isn't available.
			# This is very rare, but it happens sometimes:
			if [ "$INDEX" = '' ]
			then
				INDEX=1
				RESIZE=yes
				OFFSET=$(($OFFSET - 12))
			fi

			# Finally try to extract chosen icon:
			icotool --extract --index=$INDEX $TEMPFILE1 -o $TEMPFILE2

			if [ -s $TEMPFILE2 ]
			then
				ICON=$TEMPFILE2
				[ "$RESIZE" ] && mogrify -resize 24x24 $ICON

			else
				# This case generally happens when the hi-res icons are in new "Vista" icon format (bunch of compressed PNGs).
				# Icotool from icoutils 0.29.1 supports it already, but is unable to extract the one selected icon only.

				# Try to extract all icons:
				icotool --extract $TEMPFILE1 -o /tmp

				# There's always a 32x32x32 icon in "Vista" icons, but just to be sure:
				[ -s ${TEMPFILE1}_${INDEX}_32x32x32.png ] && ICON=${TEMPFILE1}_${INDEX}_32x32x32.png

			fi
		fi
	fi
fi


# Create the basic thumbnail:

if [ "$ICON" ]
then
	# Calculate the backgroud color:
	COLOR=$(
		convert $ICON -background white -flatten -fill white \
		-fuzz 40% -opaque black -level 33%,66% -scale 1x1! $TUNE txt:- \
		| tail -1 \
		| grep -o '#......'
	)

else
	# Just use the generic icon with backgroud color based on md5sum:
	HUE=$(md5sum "$INPUTFILE" | cut -c 1-2)
	HUE=$(printf "%d" 0x$HUE)
	COLOR="hsb($HUE, 50%, 90%)"

	LABEL=${INPUTFILE##*/}
	LABEL=$(sed 's/^./\U&/; s/.$/\L&/' <<< "${LABEL:0:2}")

	# Dim color for non-executable files:
	if [[ ! ${INPUTFILE##*.} = 'exe' ]]
	then
		LIGHT=80
		TUNE_NX='-modulate 100,20'
	fi

	convert -size 48x48 xc:none -gravity center -font Helvetica-Narrow-Bold -pointsize 24 \
	-fill '#0000005C' -annotate +1+3 "$LABEL" \
	-fill "hsb($HUE, 3%, ${LIGHT:-100}%)" -annotate +0+2 "$LABEL" \
	png:$TEMPFILE1

	ICON=$TEMPFILE1
	OFFSET=-8

fi

# Create the final thumbnail:
OFFSET=$(($OFFSET + 8))

convert -size 48x48 xc:none -fill "$COLOR" -draw "$DRAW" $TUNE_NX miff:- \
| composite -compose multiply /usr/share/pixmaps/gnome-exe-thumbnailer/$THEME/template.png - png:- \
| composite -geometry +$OFFSET+$OFFSET $ICON - $TEMPTHUMB


# Get the version number:
if [[ ${INPUTFILE##*.} = 'msi' ]]
then
#	# Look for the ProductVersion property if user has the Microsoft (R) Windows Script Host installed:
#	if [ -s "$HOME/.wine/drive_c/windows/system32/cscript.exe" ]
#	then
#		# Workaround wine bug #19799: cscript crashes if you call WScript.Arguments(0)
#		# http://bugs.winehq.org/show_bug.cgi?id=19799
#		<<< "
#			Dim WI, DB, View, Record
#			Set WI = CreateObject(\"WindowsInstaller.Installer\")
#			Set DB = WI.OpenDatabase(\"$INPUTFILE\",0)
#			Set View = DB.OpenView(\"SELECT Value FROM Property WHERE Property = 'ProductVersion'\")
#			View.Execute
#			Wscript.Echo View.Fetch.StringData(1)
#		" iconv -f utf8 -t unicode > $TEMPFILE1.vbs
#
#		VERSION=$(
#			wine cscript.exe //E:vbs //NoLogo Z:\\tmp\\${TEMPFILE1##*/}.vbs 2>/dev/null \
#			| egrep -o '^[0-9]+\.[0-9]+(\.[0-9][0-9]?)?(beta)?'
#		)
#
#	else
		# Try to get the version number from extended file properties at least:
		VERSION=$(
			file "$INPUTFILE" \
			| grep -o ', Subject: .*, Author: ' \
			| egrep -o '[0-9]+\.[0-9]+(\.[0-9][0-9]?)?(beta)?' \
			| head -1
		)
#	fi

else
	# Extract raw version resource:
	wrestool --extract --raw --type=version "$INPUTFILE" > $TEMPFILE1

	if [ -s $TEMPFILE1 ]
	then
		# Search for a sane version string.
		# This (especially the final regexp) took me really long time to figure out. Am I that lame?
		VERSION=$(< $TEMPFILE1 \
			tr '\0, ' '\t.\0' \
			| sed 's/\t\t/_/g' \
			| tr -c -d '[:print:]' \
			| sed -r -n 's/.*Version[^0-9]*([0-9]+\.[0-9]+(\.[0-9][0-9]?)?).*/\1/p'
		)
	fi
fi


# Put a version label on the thumbnail:
if [ "$VERSION" ]
then
	convert -font -*-clean-medium-r-*-*-6-*-*-*-*-*-*-* \
	-background transparent -fill white label:"$VERSION" \
	-trim -bordercolor '#00001090' -border 2 \
	-fill '#00001048' \
	-draw $'color 0,0 point\ncolor 0,8 point' -flop \
	-draw $'color 0,0 point\ncolor 0,8 point' -flop \
	miff:- | composite -gravity southeast - $TEMPTHUMB $OUTPUTFILE
else
	cp $TEMPTHUMB $OUTPUTFILE
fi


rm $TEMPFILE1* $TEMPFILE2 $TEMPTHUMB

