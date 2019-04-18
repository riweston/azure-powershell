class AsrVmDataObject {
    ## Properties
    [ array ]
    $source = @()

    [ array ]
    $target = @()
    
    ## Hidden Methods
    [ psobject ]
    Hidden
    GetVMConfig( [ string ] $ResourceGroupName, [ string ] $vm ) {
        return Get-AzVM -ResourceGroupName $ResourceGroupName -VMName $vm
    }

    [ psobject ]
    Hidden
    GetOSDisk( [ psobject ] $config ) {
        return Get-AzDisk -ResourceGroupName $config.ResourceGroupName -DiskName $config.StorageProfile.OsDisk.Name
    }

    [ array ]
    Hidden
    GetDataDisks( [ psobject ] $config ) {
        return @( $config.StorageProfile.DataDisks ).ForEach( {
                Get-AzDisk -ResourceGroupName $config.ResourceGroupName -DiskName $PSItem.Name
            })
    }
    
    [ string ]
    Hidden
    ZoneRename( [ psobject ] $obj, [ int ] $zone ) {
        switch ( $obj.name ) {
            # Append '-AZ$zone' to name field
            ( { $PSItem -notmatch "-AZ[0-9]$" }) {
                return $PSItem + '-AZ' + $zone
            }
            # Update '-AZ$zone' if it already has this notation
            ( { $PSItem -match "-AZ[0-9]$" -and $PSItem -notmatch "-AZ[$zone]$" }) {
                return ( $PSItem -split "-AZ[0-9]$" )[0] + '-AZ' + $zone
            }
        }
        # Return the name with no changes required
        return $obj.name
    }
    
    [ psobject ]
    Hidden
    AddSnapshotConfig( [ psobject ] $disk ) {
        $SnapshotConfigParams = @{
            CreateOption = "Copy"
            Location     = $disk.Location
            SourceUri    = $disk.Id
        }
        return New-AzSnapshotConfig @SnapshotConfigParams
    }
    
    ## Main Methods
    AddSourceVM( [ string ] $ResourceGroupName, [ string ] $vm ) {
        $config = $this.GetVMConfig( $ResourceGroupName, $vm )
        # Assemble object and add to .sources array
        $this.source += [pscustomobject] @{
            name      = & { $config.name }
            config    = & { $config }
            osdisk    = & { $this.GetOSDisk( $config ) }
            datadisks = & { $this.GetDataDisks( $config ) }          
        }
    }
    
    GetResourceGroupVms( [ string ] $ResourceGroupName ) {
        @( Get-AzVM -ResourceGroupName $ResourceGroupName ).ForEach( { 
                $this.AddSourceVM( $_.ResourceGroupName, $_.Name )
            })
    }

    AddTargetVM( [ string ] $ResourceGroupName, [ string ] $vm, [ int ] $zone ) {
        # Verify object to be transformed exists & deep copy obj
        [ psobject ] $tempTarget = $this.source.Where( {
                $_.config.ResourceGroupName -like $ResourceGroupName -and 
                $_.Name -like $vm 
            } ) | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        # Additional properties that should be captured
        $tempTarget | Add-Member -MemberType NoteProperty -Name "osdisksnapshot" -Value ( New-object System.Collections.Arraylist )
        $tempTarget | Add-Member -MemberType NoteProperty -Name "datadisksnapshot" -Value ( New-object System.Collections.Arraylist )
        $tempTarget | Add-Member -MemberType NoteProperty -Name 'zone' -Value $zone
        # Rename to '-AZ#' format
        $tempTarget.name = $this.ZoneRename( $tempTarget, $zone )
        $tempTarget.config.name = $this.ZoneRename( $tempTarget.config, $zone )
        $tempTarget.osdisk.name = $this.ZoneRename( $tempTarget.osdisk, $zone )
        # Generate & capture the snapshot config
        $tempTarget.osdisksnapshot += $this.AddSnapshotConfig( $tempTarget.osdisk )
        @( $tempTarget.datadisks ).ForEach( {
                $PSItem = $this.ZoneRename( $PSItem, $zone )
                $tempTarget.datadisksnapshot += $this.AddSnapshotConfig( $PSItem )
            })
        # Append to the .target property
        $this.target += $tempTarget
    }

    ## WIP
    DataProcessor( $zone ) {
        $this.target = $null
        @( $this.source ) | ForEach-Object {
            $tempTarget = $PSItem | ConvertTo-Json | ConvertFrom-Json
            $tempTarget.name = $PSItem.name + '-AZ' + $zone
            $tempTarget.config.name = $PSItem.tempTarget.config.name + '-AZ' + $zone
            $tempTarget.osdisk.name = $PSItem.osdisk.name + '-AZ' + $zone
            @( $tempTarget.datadisks ).ForEach( {
                    $PSItem.name = $PSItem.name + '-AZ' + $zone
                })
            $this.target += $tempTarget
            # Sanitise properties
            $this.config = [ psobject ] $null
            $this.osdisk = [ psobject ] $null
            $this.datadisks = @()
            $tempTarget = [ psobject ] $null
        }
    }
}
