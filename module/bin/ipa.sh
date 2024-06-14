#!/bin/bash

source "$STAGE"

function copy { 
	rsync -a "$@" --exclude _MTN --exclude .git --exclude .svn --exclude .DS_Store --exclude ._*
}

if [[ -d $RESOURCES_DIR ]]; then
	log 2 "Copying resources"
	copy "$RESOURCES_DIR"/ "$appdir" --exclude "/Info.plist"
fi

bundle_id_xpath="/plist/dict/key[text()=\"CFBundleIdentifier\"]/following-sibling::*[1]/text()"

function change_bundle_id {
	bundle_id=$(xmlstarlet sel -t -c "$bundle_id_xpath" "$1")
	xmlstarlet ed -L -u "$bundle_id_xpath" -v "$BUNDLE_ID${bundle_id#$app_bundle_id}" "$1"
}

xmlstarlet ed -L -s "/plist/dict" -t elem -n key -v "ALTBundleIdentifier" "$info_plist"
xmlstarlet ed -L -s "/plist/dict" -t elem -n string -v "$app_bundle_id" "$info_plist"

rm -rf $appdir/_CodeSignature/CodeResources

if [[ $_REMOVE_EXTENSIONS = 1 ]]; then
	rm -rf $appdir/PlugIns
fi

if [[ -n $BUNDLE_ID ]]; then
	log 2 "Setting bundle ID"
	export -f change_bundle_id
	export app_bundle_id
	find "$appdir" -name "*.appex" -print0 | xargs -I {} -0 bash -c "change_bundle_id '{}/Info.plist'"
	xmlstarlet ed -L -u "$bundle_id_xpath" -v "$BUNDLE_ID" "$info_plist"
fi

if [[ -n $DISPLAY_NAME ]]; then
	log 2 "Setting display name"
	xmlstarlet ed -L -u "/plist/dict/key[text()=\"CFBundleDisplayName\"]/following-sibling::*[1]/text()" -v "$DISPLAY_NAME" "$info_plist"
fi

# TODO: merge plist files with xmlstarlet
if [[ -f $RESOURCES_DIR/Info.plist ]]; then
	log 2 "Merging Info.plist"
	copy "$RESOURCES_DIR/Info.plist" "$STAGING_DIR"
	/usr/libexec/PlistBuddy -c "Merge $info_plist" "$STAGING_DIR/Info.plist"
	mv "$STAGING_DIR/Info.plist" "$appdir"
fi

log 2 "Copying dependencies"
inject_files=("$DYLIB" $INJECT_DYLIBS)
copy_files=($EMBED_FRAMEWORKS $EMBED_LIBRARIES)
[[ $USE_CYCRIPT = 1 ]] && inject_files+=("$CYCRIPT")
[[ $USE_FLEX = 1 ]] && inject_files+=("$FLEX")
[[ $USE_OVERLAY = 1 ]] && inject_files+=("$OVERLAY")
[[ $GENERATOR == "MobileSubstrate" ]] && copy_files+=("$SUBSTRATE")

full_copy_path="$appdir/$COPY_PATH"
mkdir -p "$full_copy_path"
for file in "${inject_files[@]}" "${copy_files[@]}"; do
	copy "$file" "$full_copy_path"
done

bundle_files=($EMBED_BUNDLES)

for file in "${bundle_files[@]}"; do
	copy -L "$file" "$appdir"
done

appex_files=($EMBED_EXTENSIONS)

full_appex_path="$appdir/$APPEX_PATH"
if [[ ! -z appex_files ]]; then
	if [[ ! -f $full_appex_path ]]; then
		mkdir $full_appex_path
	fi
	for file in "${appex_files[@]}"; do
		copy "$file" "$full_appex_path"
	done
fi

log 3 "Injecting dependencies"
app_binary="$appdir/$(xmlstarlet sel -t -c "/plist/dict/key[text()=\"CFBundleExecutable\"]/following-sibling::*[1]/text()" "$info_plist")"
"$INSTALL_NAME_TOOL" -add_rpath "@executable_path/$COPY_PATH" "$app_binary"
for file in "${inject_files[@]}"; do
	filename=$(basename "$file")
	"$INSTALL_NAME_TOOL" -change "$STUB_SUBSTRATE_INSTALL_PATH" "$SUBSTRATE_INSTALL_PATH" "$full_copy_path/$filename"
	if [[ $? != 0 ]]; then
		error "Failed to change substrate install path in $filename"
	fi
	"$INSERT_DYLIB" --inplace --weak --no-strip-codesig "@rpath/$(basename "$file")" "$app_binary"
	if [[ $? != 0 ]]; then
		error "Failed to inject $filename into $app"
	fi
done

chmod +x "$app_binary"

if [[ $_CODESIGN_IPA = 1 ]]; then
	log 4 "Signing $app"

	if [[ ! -r $PROFILE ]]; then
		bundleprofile=$(grep -Fl "<string>iOS Team Provisioning Profile: $PROFILE</string>" ~/Library/MobileDevice/Provisioning\ Profiles/* | head -1)
		if [[ ! -r $bundleprofile ]]; then
			error "Could not find profile '$PROFILE'"
		fi
		PROFILE="$bundleprofile"
	fi

	if [[ $_EMBED_PROFILE = 1 ]]; then
		copy "$PROFILE" "$appdir/embedded.mobileprovision"
	fi

	security cms -Di "$PROFILE" -o "$PROFILE_FILE"
	if [[ $? != 0 ]]; then
		error "Failed to generate entitlements"
	fi

	if [[ -n $DEV_CERT_NAME ]]; then
		codesign_name=$(security find-certificate -c "$DEV_CERT_NAME" login.keychain | grep alis | cut -f4 -d\" | cut -f1 -d\")
	else
		# http://maniak-dobrii.com/extracting-stuff-from-provisioning-profile/
		codesign_name=$(xmlstarlet sel -t -v "/plist/dict/key[text()=\"DeveloperCertificates\"]/following-sibling::*/*" "$PROFILE_FILE" | openssl x509 -noout -inform DER -subject | sed -E 's/.*CN[[:space:]]*=[[:space:]]*([^,]+).*/\1/')
	fi
	if [[ -z $codesign_name ]]; then
		error "Failed to get codesign name"
	fi

	xmlstarlet sel -t -c "/plist/dict/key[text()=\"Entitlements\"]/following-sibling::*[1]" "$PROFILE_FILE" > "$ENTITLEMENTS"
	if [[ $? != 0 ]]; then
		error "Failed to generate entitlements"
	fi
	
	find "$appdir" \( -name "*.framework" -or -name "*.dylib" -or -name "*.appex" \) -not -path "*.framework/*" -print0 | xargs -0 codesign --entitlements "$ENTITLEMENTS" -fs "$codesign_name"
	if [[ $? != 0 ]]; then
		error "Codesign failed"
	fi
	
	codesign -fs "$codesign_name" --entitlements "$ENTITLEMENTS" "$appdir"
	if [[ $? != 0 ]]; then
		error "Failed to sign $app"
	fi
fi

cd "$STAGING_DIR"
if [[ "${OUTPUT_NAME##*.}" = "app" ]]; then
	cp -a "$appdir" "$PACKAGES_DIR/$OUTPUT_NAME"
else
	log 4 "Repacking $app"
	zip -yqr$COMPRESSION "$OUTPUT_NAME" Payload/
	if [[ $? != 0 ]]; then
		error "Failed to repack $app"
	fi
	mv "$OUTPUT_NAME" "$PACKAGES_DIR/"
fi
