        ; Loader part
        ; ELoad (SD2IEC) support based on work of Thomas 'skoe' Giesel

                include memory.s
                include kernal.s
                include ldepacksym.s

LOAD_KERNAL     = $00           ;Load using Kernal and do not allow interrupts
LOAD_FAKEFAST   = $01           ;Load using Kernal, interrupts allowed
LOAD_EASYFLASH  = $02           ;Load using EasyFlash cartridge
LOAD_GMOD2      = $03           ;Load using GMod2 cartridge
LOAD_FAST       = $ff           ;(or any other negative value) Load using custom serial protocol

MW_LENGTH       = 32            ;Bytes in one M-W command

tablBi          = depackBuffer
tablLo          = depackBuffer + 52
tablHi          = depackBuffer + 104

iddrv0          = $12           ;Disk drive ID (1541 only)
id              = $16           ;Disk ID (1541 only)

drvFileTrk      = $0300
drvFileSct      = $0380
drvBuf          = $0400         ;Sector data buffer
drvStart        = $0400
drvSendTblHigh  = $0700
InitializeDrive = $d005         ;1541 only

loaderCodeStart = FastLoadEnd
ELoadHelper     = $0200

                org loaderCodeStart

        ; Loader runtime data

ntscFlag:       dc.b $00
fileNumber:     dc.b $00                        ;Initial filenumber for the main part
loaderMode:     dc.b LOAD_KERNAL

loaderCodeEnd:

        ; Loader initialization / entrypoint, 3 bytes from loader loadaddress

InitLoader:     lda $d011
                and #$0f
                sta $d011                       ;Blank screen
                lda #$02
                jsr Close                       ;Close the file loaded from
                ldx #$00
                stx fileOpen
                stx loaderMode                  ;Assume Kernal (fallback) mode
                stx ntscFlag
                stx fileNumber
IL_DetectNtsc1: lda $d012                       ;Detect PAL/NTSC/Drean
IL_DetectNtsc2: cmp $d012
                beq IL_DetectNtsc2
                bmi IL_DetectNtsc1
                cmp #$20
                bcc IL_IsNtsc
IL_CountCycles: inx
                lda $d012
                bpl IL_CountCycles
                cpx #$8d
                bcc IL_IsPal
                bcs IL_IsDrean
IL_IsNtsc:      inc ntscFlag
IL_IsDrean:     lda #$f0                        ;Adjust 2-bit transfer delay for NTSC / Drean
                sta ilFastLoadStart+FL_Delay-OpenFile
IL_IsPal:       lda $dc00                       ;Check for safe mode loader
                and $dc01
                and #$10
                bne IL_DetectDriveID
IL_SafeMode:    lda #$06
                sta $d020
                bne IL_NoFastLoad

IL_NoSerial:    inc loaderMode                  ;Serial bus not used: switch to "fake" IRQ-loading mode
IL_NoFastLoad:  lda #<(ilSlowLoadStart-1)
                sta IL_CopyLoaderCode+1
                lda #>(ilSlowLoadStart-1)
                sta IL_CopyLoaderCode+2
                ldx #ilStopIrqCodeEnd-ilStopIrqCodeStart-1
IL_CopyStopIrq: lda ilStopIrqCodeStart,x       ;Default IRQ stop code for Kernal loading: just wait for bottom of screen
                sta StopIrq,x
                dex
                bpl IL_CopyStopIrq
                jmp IL_Done

        ; Drive detection stage 1: read ID

IL_DetectDriveID:
                lda #$02                        ;Reset drive, read back ID, using only non-serial routines
                ldx #<ilUICmd
                ldy #>ilUICmd
                jsr SetNam
                lda #$0f
                tay
                ldx fa
                jsr SetLFS
                jsr Open
                ldx #$0f
                jsr ChkIn
                ldx #$07
IL_ReadID:      jsr ChrIn
                sta ilIDBuffer-1,x
                dex
                bne IL_ReadID
                lda #$0f
                jsr Close
                ldx #$ff
IL_IDMismatch:  lda #$04
                sta loadTempReg
IL_IDNext:      inx
                cpx #$10
                bcs IL_UploadDriveCode          ;No IDs detected, proceed to drivecode-based detection
                txa
                and #$03
                tay
                lda ilIDBuffer,y
                cmp ilIDStrings,x
                bne IL_IDMismatch
                dec loadTempReg                 ;Increase match count
                bne IL_IDNext
                cpx #$08
                bcc IL_NoSerial                 ;First two IDs are non-serial devices, the last two are SD2IEC

IL_HasSD2IEC:   ldx #$00
IL_CopyELoadHelper:
                lda ilELoadHelper,x             ;Copy full 256 bytes (sector buffer) of ELoad helper code, exact length doesn't matter
                sta ELoadHelper,x
                inx
                bne IL_CopyELoadHelper
                lda #<(ilELoadStart-1)
                sta IL_CopyLoaderCode+1
                lda #>(ilELoadStart-1)
                sta IL_CopyLoaderCode+2
                jmp IL_FastLoadOK               ;ELoad is a fastloader protocol, which doesn't need especial delay

        ; Drive detection stage 2: upload drivecode to detect serial drive type

IL_NoSD2IEC:
IL_UploadDriveCode:
                ldy #$00                        ;Init selfmodifying addresses
                beq UDC_NextPacket
UDC_SendMW:     lda ilMWString,x                ;Send M-W command (backwards)
                jsr CIOut
                dex
                bpl UDC_SendMW
                ldx #MW_LENGTH
UDC_SendData:   lda ilDriveCode,y              ;Send one byte of drive code
                jsr CIOut
                iny
                bne UDC_NotOver
                inc UDC_SendData+2
UDC_NotOver:    inc ilMWString+2               ;Also, move the M-W pointer forward
                bne UDC_NotOver2
                inc ilMWString+1
UDC_NotOver2:   dex
                bne UDC_SendData
                jsr UnLsn                       ;Unlisten to perform the command
UDC_NextPacket: lda fa                          ;Set drive to listen
                jsr Listen
                lda status                      ;Quit to safe mode if error
                bmi IL_NoFastLoad2
                lda #$6f
                jsr Second
                ldx #$05
                dec ilNumPackets                ;All "packets" sent?
                bpl UDC_SendMW
UDC_SendME:     lda ilMEString-1,x              ;Send M-E command (backwards)
                jsr CIOut
                dex
                bne UDC_SendME
                jsr UnLsn
IL_WaitDataLow: lda status
                bmi IL_NoFastLoad2
                bit $dd00                       ;Wait for drivecode to signal activation with DATA=low
                bpl IL_FastLoadOK               ;If not detected within time window, use slow loading
                dex
                bne IL_WaitDataLow
IL_NoFastLoad2: jmp IL_NoFastLoad

IL_FastLoadOK:  dec loaderMode                  ;Switch to IRQ-loader mode
IL_Done:        ldx #ilFastLoadEnd-ilFastLoadStart
IL_CopyLoaderCode:
                lda ilFastLoadStart-1,x         ;Copy either fastload or slowload IO code
                sta OpenFile-1,x
                dex
                bne IL_CopyLoaderCode
                lda #$35                        ;ROMs off
                sta $01
                lda #>(loaderCodeEnd-1)         ;Store mainpart entrypoint to stack
                pha
                lda #<(loaderCodeEnd-1)
                pha
                lda #<loaderCodeEnd
                ldx #>loaderCodeEnd
                jmp LoadFile                    ;Load mainpart (overwrites loader init)

        ; Slow fileopen / getbyte / save routines

ilSlowLoadStart:

                rorg OpenFile

        ; Open file
        ;
        ; Parameters: fileNumber
        ; Returns: -
        ; Modifies: A,X,Y

                jmp SlowOpen

        ; Save file
        ;
        ; Parameters: A,X startaddress, zpBitsLo-Hi amount of bytes, fileNumber
        ; Returns: -
        ; Modifies: A,X,Y

                jmp SlowSave

        ; Read a byte from an opened file
        ;
        ; Parameters: -
        ; Returns: if C=0, byte in A. If C=1, EOF/errorcode in A:
        ; $00 - EOF (no error)
        ; $02 - File not found
        ; $80 - Device not present
        ; Modifies: A

SlowGetByte:    lda fileOpen
                beq SGB_Closed
                sta $01
                jsr ChrIn
                pha
                lda status
                bne SGB_EOF
                dec $01
SGB_LastByte:   pla
                clc
SO_Done:        rts
SGB_EOF:        and #$83
                sta SGB_Closed+1
                php
                stx loadTempReg
                sty loadBufferPos
                jsr CloseKernalFile
                ldx loadTempReg
                ldy loadBufferPos
                plp
                beq SGB_LastByte
                pla
SGB_Closed:     lda #$00
                sec
                rts

SlowOpen:       lda fileOpen
                bne SO_Done
                jsr PrepareKernalIO
                jsr SetFileName
                ldy #$00                        ;A is $02 here
                jsr SetLFSOpen
                jsr ChkIn
                dec $01                         ;Kernal off after opening
                rts

SlowSave:       sta zpSrcLo
                stx zpSrcHi
                jsr PrepareKernalIO
                lda #$05
                ldx #<scratch
                ldy #>scratch
                jsr SetNam
                lda #$0f
                tay
                jsr SetLFSOpen
                lda #$0f
                jsr Close
                jsr SetFileName
                ldy #$01                        ;Open for write
                jsr SetLFSOpen
                jsr ChkOut
                ldy #$00
                ldx zpBitsHi
SS_Loop:        lda (zpSrcLo),y
                jsr ChrOut
                iny
                bne SS_NoMSB
                inc zpSrcHi
                dex
SS_NoMSB:       cpy zpBitsLo
                bne SS_Loop
                txa
                bne SS_Loop
CloseKernalFile:lda #$02
                jsr Close
                lda #$00
                sta fileOpen
                dec $01
                rts

PrepareKernalIO:jsr StopIrq
                lda #$36
                sta fileOpen                    ;Set fileopen indicator, raster delays are to be expected
                sta $01
                ldx #$00
                if USETURBOMODE > 0
                stx $d07a                       ;SCPU to slow mode
                stx $d030                       ;C128 back to 1MHz mode
                endif
                lda fileNumber                  ;Convert filename
                pha
                lsr
                lsr
                lsr
                lsr
                jsr CFN_Sub
                pla
                and #$0f
                inx
CFN_Sub:        ora #$30
                cmp #$3a
                bcc CFN_Number
                adc #$06
CFN_Number:     sta fileName,x
                rts

SetFileName:    lda #$02
                ldx #<fileName
                ldy #>fileName
                jmp SetNam

SetLFSOpen:     ldx fa
                jsr SetLFS
                jsr Open
                ldx #$02
                rts

scratch:        dc.b "S0:"
fileName:       dc.b "  "

SlowLoadEnd:

                rend

ilSlowLoadEnd:

ilStopIrqCodeStart:

                rorg StopIrq
StopIrqWait:    lda $d011
                bpl StopIrqWait                 ;Wait until bottom to make sure IRQ's adjust themselves to fileOpen flag
                rts
                rend

ilStopIrqCodeEnd:

        ; Fast fileopen / getbyte / save routines

ilFastLoadStart:

                rorg OpenFile

        ; Open file
        ;
        ; Parameters: fileNumber
        ; Returns: -
        ; Modifies: A,X,Y

                jmp FastOpen

        ; Save file
        ;
        ; Parameters: A,X startaddress, zpBitsLo-Hi amount of bytes, fileNumber
        ; Returns: -
        ; Modifies: A,X,Y

                jmp FastSave

        ; Read a byte from an opened file
        ;
        ; Parameters: -
        ; Returns: if C=0, byte in A. If C=1, EOF/errorcode in A:
        ; $00 - EOF (no error)
        ; $02 - File not found
        ; $80 - Device not present
        ; Modifies: A

GetByte:        stx loadTempReg
                ldx loadBufferPos
                lda loadBuffer,x
GB_EndCmp:      cpx #$00
                bcs FL_FillBuffer
                inc loadBufferPos
GB_FileEnd:     ldx loadTempReg
FO_Done:
SetSpriteRangeDummy:
                rts

FastOpen:       lda fileOpen                    ;A file already open? If so, do nothing
                bne FO_Done                     ;(allows chaining of files)
                inc fileOpen
                if USETURBOMODE > 0
                sta $d07a                       ;SCPU to slow mode
                sta $d030                       ;C128 back to 1MHz mode
                endif
                jsr FL_SendCmdAndFileName       ;Command 0 = load
FL_SetSpriteRangeJsr:                           ;This will be changed by game to set sprite Y-range before transfer
                jsr SetSpriteRangeDummy
FL_FillBuffer:  ldx fileOpen                    ;If file closed, errorcode in A & C=1
                beq GB_FileEnd
                dex                             ;X=0
                pha                             ;Preserve A (the byte that was read if called from GetByte) & Y
FL_FillBufferWait:
                bit $dd00                       ;Wait for 1541 to signal data ready by setting DATA high
                bpl FL_FillBufferWait
FL_FillBufferLoop:
FL_SpriteWait:  lda $d012                       ;Check for sprite Y-coordinate range
FL_MaxSprY:     cmp #$00                        ;(max & min values are filled in the
                bcs FL_NoSprites                ;raster interrupt)
FL_MinSprY:     cmp #$00
                bcs FL_SpriteWait
FL_NoSprites:   sei
FL_WaitBadLine: lda $d011
                clc
                sbc $d012
                and #$07
                beq FL_WaitBadLine
                lda #$10
                nop
                sta $dd00                       ;Set CLK low
                lda #$00
                nop
                sta $dd00                       ;Set CLK high
FL_Delay:       bne FL_ReceiveByte              ;2 cycles on PAL, 3 on NTSC
FL_ReceiveByte: lda $dd00
                lsr
                lsr
                eor $dd00
                lsr
                lsr
                eor $dd00
                lsr
                lsr                             ;C=0 for looping again & return (no EOF or error)
                eor $dd00
                cli
FL_Sta:         sta loadBuffer,x
                inx
FL_NextByte:    bne FL_FillBufferLoop
                dex                             ;X=$ff (end cmp for full buffer)
                lda loadBuffer
                bne FL_FullBuffer
                ldx loadBuffer+1                ;File ended if T&S both zeroes
                bne FL_PartialBuffer
                dec fileOpen
                ldx #$02
FL_PartialBuffer:
FL_FullBuffer:  stx GB_EndCmp+1
                pla                             ;Restore A
                ldx #$02
                stx loadBufferPos               ;Set buffer read position
                bne GB_FileEnd                  ;Restore X & return

FL_SendCmdAndFileName:
                ora fileNumber
FL_SendByte:    sta loadTempReg
                ldx #$08                        ;Bit counter
FL_SendLoop:    bit $dd00                       ;Wait for both DATA & CLK to go high
                bpl FL_SendLoop
                bvc FL_SendLoop
                lsr loadTempReg                 ;Send one bit
                lda #$10
                bcc FL_ZeroBit
                eor #$30
FL_ZeroBit:     sta $dd00
                lda #$c0                        ;Wait for CLK & DATA low (diskdrive answers)
FL_SendAck:     bit $dd00
                bne FL_SendAck
                lda #$00                        ;CLK & DATA both high after sending 1 bit
                sta $dd00
                dex
                bne FL_SendLoop
                rts

FastSave:       sta zpSrcLo
                stx zpSrcHi
                lda #$80                        ;Command $80 = save
                jsr FL_SendCmdAndFileName
                lda zpBitsLo
                jsr FL_SendByte
                lda zpBitsHi
                jsr FL_SendByte
                tay
FS_Loop:        lda (zpSrcLo),y
                jsr FL_SendByte
                iny
                bne FS_NoMSB
                inc zpSrcHi
                dec zpBitsHi
FS_NoMSB:       cpy zpBitsLo
                bne FS_Loop
                lda zpBitsHi
                bne FS_Loop
                rts

FastLoadEnd:

                rend

ilFastLoadEnd:

        ; ELoad helper code / IEC protocol implementation

ilELoadHelper:

                rorg ELoadHelper

        ; IEC communication routines

EL_ListenAndSecond:
                pha
                lda fa
                ora #$20
                jsr EL_SendByteATN
                pla
                jsr EL_SendByteATN
                lda #$10                        ;After the secondary address, just CLK low for further non-ATN bytes
                sta $dd00
                rts

EL_SendByteATN: sta loadTempReg
                lda #$08
                bne EL_SendByteCommon

EL_SendByte:    sta loadTempReg
EL_WaitDataLow: bit $dd00                       ;For non-ATN bytes, wait for DATA low before we continue
                bmi EL_WaitDataLow
                lda #$00
EL_SendByteCommon:
                sta $dd00                       ;CLK high -> ready to send; wait for DATA high response
                jsr EL_WaitDataHigh
                pha
                lda #$40
                sec
EL_WaitEOI:     sbc #$01                        ;Wait until we are sure to have generated an EOI response
                cmp #$09                        ;It doesn't matter that every byte we send is with EOI
                bcs EL_WaitEOI
                jsr EL_WaitDataHigh             ;Wait for DATA high again (EOI response over)
                lda #$08
                sta loadBufferPos               ;Bit counter
                pla
                beq EL_SendByteLoop
EL_SendWaitBorder:
                bit $d011                       ;On SD2IEC the last bit of Listen/Unlisten is critical to send undelayed
                bpl EL_SendWaitBorder           ;as delay means JiffyDOS activation. Wait for border (no interrupts) for ATN bytes
EL_SendByteLoop:and #$08                        ;CLK low
                ora #$10
                jsr EL_SetLineAndDelay          ;Use JSR to set $dd00 to apply a delay
                dec loadBufferPos
                bmi EL_SendByteDone
                and #$08
                lsr loadTempReg
                bcs EL_SendBitOne
                ora #$20                        ;CLK high + data bit
EL_SendBitOne:  jsr EL_SetLineAndDelay
                jmp EL_SendByteLoop

EL_SetLineAndDelay:
                jsr EL_SetLine
                jsr EL_SetLine
EL_SendByteDone:rts

        ; Init the eload1 drivecode

EL_Init:        lda #"W"
                ldx #<eloadMWStringEnd
                jsr EL_SendCommand
                lda #"E"
                ldx #<eloadMEStringEnd
EL_SendCommand: sta eloadMWString+2
                ldy #<eloadMWString
                lda #$6f
                jsr EL_ListenAndSecond
EL_SendBlock:   stx EL_SendEndCmp+1
EL_SendBlockLoop:
                lda ELoadHelper,y
                jsr EL_SendByte
                iny
EL_SendEndCmp:  cpy #$00
                bcc EL_SendBlockLoop
EL_Unlisten:    lda #$3f                        ;Unlisten command always after a block
                jsr EL_SendByteATN
                jsr EL_SetLinesIdle             ;Let go of DATA+CLK+ATN
EL_WaitDataHigh:bit $dd00                       ;Wait until device lets go of the DATA line
                bpl EL_WaitDataHigh             
                rts

        ; Send load command by fast protocol

EL_SendLoadCmdFast: 
                bit $dd00                       ;Wait for drive to signal ready to receive
                bvs EL_SendLoadCmdFast          ;with CLK low
                ldx #$20                        ;Pull DATA low to acknowledge
                stx $dd00
EL_SendFastWait:bit $dd00                       ;Wait for drive to release CLK
                bvc EL_SendFastWait
EL_SendFastWaitBorder:  
                bit $d011                       ;Wait to be in border for no badlines
                bpl EL_SendFastWaitBorder
                jsr EL_SetLinesIdle             ;Waste cycles / send 0 bits
                jsr EL_SetLinesIdle
                jsr EL_Delay12                  ;Send the lower nybble (always 1)
                stx $dd00
                nop
                nop
EL_SetLinesIdle:lda #$00                        ;Rest of bits / idle value
EL_SetLine:     sta $dd00
                nop
EL_Delay12:     rts

        ; Subroutine for filename conversion

EL_CFNSub:      ora #$30
                cmp #$3a
                bcc EL_CFNNumber
                adc #$06
EL_CFNNumber:   sta eloadFileName,x
                rts

        ; Strings

eloadMWString:  dc.b "M-W"
                dc.w $0300
eloadMEStringEnd:
                dc.b 6
                dc.b "eload1"
eloadMWStringEnd:

eloadReplace:   dc.b "@0:"
eloadFileName:  dc.b "  "
eloadFileNameEnd:

ELoadHelperEnd:
                rend

ilELoadHelperEnd:

        ; ELoad (SD2IEC) fileopen / getbyte / save routines

ilELoadStart:

                rorg OpenFile

        ; Open file
        ;
        ; Parameters: fileNumber
        ; Returns: -
        ; Modifies: A,X,Y

                jmp ELoadOpen

        ; Save file
        ;
        ; Parameters: A,X startaddress, zpBitsLo-Hi amount of bytes, fileNumber
        ; Returns: -
        ; Modifies: A,X,Y

                jmp ELoadSave

        ; Read a byte from an opened file
        ;
        ; Parameters: -
        ; Returns: if C=0, byte in A. If C=1, EOF/errorcode in A:
        ; $00 - EOF (no error)
        ; $02 - File not found
        ; $80 - Device not present
        ; $ff - File not found (SD2IEC)
        ; Modifies: A

ELoadGetByte:   lda fileOpen
                beq EL_GetByteEOF
                jsr EL_GetByteFast
                dec loadBufferPos
                beq EL_Refill
EL_SetSpriteRangeDummy:
EL_NoRefill:    rts

EL_GetByteEOF:lda loadBufferPos
                sec
                rts

ELoadOpen:      lda fileOpen                    ;File already open?
                bne EL_OpenDone
                lda #$f0                        ;Open for read
                jsr EL_OpenFileShort
                jsr EL_Init
                jsr EL_SendLoadCmdFast
EL_SetSpriteRangeJsr:                           ;This will be changed by game to set sprite Y-range before transfer
                jsr EL_SetSpriteRangeDummy
EL_Refill:      pha
                jsr EL_GetByteFast
                bcc EL_RefillFinish

EL_GetByteFast:
                bit $dd00                       ;Wait for drive to signal data ready with
                bmi EL_GetByteFast            ;DATA low
EL_SpriteWait:  lda $d012                       ;Check for sprite Y-coordinate range
EL_MaxSprY:     cmp #$00                        ;(max & min values are filled in the
                bcs EL_NoSprites              ;raster interrupt)
EL_MinSprY:     cmp #$00
                bcs EL_SpriteWait
EL_NoSprites:   sei
EL_BadlineWait:
                lda $d011
                clc
                sbc $d012
                and #7
                beq EL_BadlineWait
                nop
                nop
                lda #$10                        ;Signal transmission with CLK low - CLK high
                sta $dd00
                bit loadTempReg
                lda #$00
                sta $dd00
                pha                             ;Waste 14 cycles before reading
                pla
                pha
                pla
                lda $dd00
                lsr
                lsr
                eor $dd00
                lsr
                lsr
                eor $dd00
                lsr
                lsr
                clc                             ; This used to be the EOR for supporting multiple videobanks
                eor $dd00
                cli
                rts

EL_RefillFinish:sta loadBufferPos               ;Bytes left, EOF ($00) or error ($ff)
                beq EL_FileEnded
                cmp #$ff
                bcc EL_RefillDone
EL_FileEnded:   lda #$e0
EL_FileEndedFinish:
                jsr EL_CloseFile
                clc
EL_RefillDone:  pla
EL_OpenDone:    rts

ELoadSave:      sta zpSrcLo
                stx zpSrcHi
                lda #$f1                        ;Open for write
                ldy #<eloadReplace              ;Use the long filename with replace command
                jsr EL_OpenFile
                lda #$61
                jsr EL_ListenAndSecond          ;Open write stream
                ldx zpBitsHi
                ldy #$00
EL_SaveLoop:    lda (zpSrcLo),y
                jsr EL_SendByte
                iny
                bne EL_SaveNoMSB
                inc zpSrcHi
                dex
EL_SaveNoMSB:   cpy zpBitsLo
                bne EL_SaveLoop
                txa
                bne EL_SaveLoop
                jsr EL_Unlisten
                lda #$e1
EL_CloseFile:   jsr EL_ListenAndSecond
                jsr EL_Unlisten
                dec fileOpen
                rts

EL_OpenFileShort:
                ldy #<eloadFileName
EL_OpenFile:    inc fileOpen
                ldx #$00
                if USETURBOMODE > 0
                stx $d07a                       ;SCPU to slow mode
                stx $d030                       ;C128 back to 1MHz mode
                endif
                jsr EL_ListenAndSecond
                lda fileNumber                  ;Convert filename
                pha
                lsr
                lsr
                lsr
                lsr
                jsr EL_CFNSub
                pla
                and #$0f
                inx
                jsr EL_CFNSub
                ldx #<eloadFileNameEnd
                jmp EL_SendBlock

ELoadEnd:
                rend

ilELoadEnd:

                if ilFastLoadEnd - ilFastLoadStart > $ff
                err
                endif

                if ilSlowLoadEnd - ilSlowLoadStart > $ff
                err
                endif

                if ilELoadEnd - ilELoadStart > $ff
                err
                endif

                if SlowLoadEnd > FastLoadEnd
                err
                endif

                if ELoadEnd > FastLoadEnd
                err
                endif

                if ELoadHelperEnd > $0300
                err
                endif

                if FL_MaxSprY != EL_MaxSprY
                err
                endif

                if FL_MinSprY != EL_MinSprY
                err
                endif

                if FL_SetSpriteRangeJsr != EL_SetSpriteRangeJsr
                err
                endif

ilDriveCode:
                rorg drvStart

        ; 1MHz transfer routine

Drv1MHzSend:    ldx #$00
Drv1MHzSendLoop:lda drvBuf
                tay
                and #$0f
                stx $1800                       ;Set DATA=high to mark data available
                tax
                lda drvSendTbl,x
Drv1MHzWait:    ldx $1800                       ;Wait for CLK=low
                beq Drv1MHzWait
                sta $1800
                asl
                and #$0f
                sta $1800
                lda drvSendTblHigh,y
                sta $1800
                asl
                and #$0f
                sta $1800
                inc Drv2MHzSend+Drv1MHzSendLoop-Drv1MHzSend+1
                bne Drv1MHzSendLoop
                dc.b $f0,$0b                    ;beq DrvSendDone
Drv1MHzSendEnd:

drvFamily:      dc.b $43,$0d,$ff

DrvDetect:      sei
                ldy #$01
DrvIdLda:       lda $fea0                       ;Recognize drive family
                ldx #$03                        ;(from Dreamload)
DrvIdLoop:      cmp drvFamily-1,x
                beq DrvFFound
                dex                             ;If unrecognized, assume 1541
                bne DrvIdLoop
                beq DrvIdFound
DrvFFound:      lda #<(drvIdByte-1)
                sta DrvIdLoop+1
                lda drvIdLocLo-1,x
                sta DrvIdLda+1
                lda drvIdLocHi-1,x
                sta DrvIdLda+2
                dey
                bpl DrvIdLda
DrvIdFound:     ldy drvJobTrkLo,x                ;Patch job track/sector
                sty DrvReadTrk+1
                iny
                sty DrvReadSct+1
                lda drvJobTrkHi,x
                sta DrvReadTrk+2
                sta DrvReadSct+2
                txa
                bne DrvNot1541
                lda #$2c                        ;On 1541/1571, patch out the flush ($a2) job call
                sta DrvFlushJsr
                lda #$7a                        ;Set data direction so that can compare against $1800 being zero
                sta $1802
                lda $e5c6
                cmp #$37
                bne DrvNot1571                  ;Recognize 1571 as a subtype
                jsr DrvNoData                   ;Set DATA=low already here, as $904e takes a long time and we would be too late for C64
                jsr $904e                       ;Enable 2Mhz mode, overwrites buffer at $700
                jmp DrvDetectDone
DrvNot1571:     ldy #Drv1MHzSendEnd-Drv1MHzSend ;For non-1571, copy 1MHz transfer code
Drv1MHzCopy:    lda Drv1MHzSend,y
                sta Drv2MHzSend,y
                dey
                bpl Drv1MHzCopy
                bmi DrvDetectDone
DrvNot1541:     lda drvDirTrkLo-1,x             ;Patch directory track/sector
                sta DrvDirTrk+1
                lda drvDirTrkHi-1,x
                sta DrvDirTrk+2
                lda drvDirSctLo-1,x
                sta DrvDirSct+1
                lda drvDirSctHi-1,x
                sta DrvDirSct+2
                lda drvExecLo-1,x               ;Patch job exec address
                sta DrvExecJsr+1
                lda drvExecHi-1,x
                sta DrvExecJsr+2
                lda drvLedBit-1,x               ;Patch drive led accesses
                sta DrvLed+1
                lda drvLedAdrHi-1,x
                sta DrvLedAcc0+2
                sta DrvLedAcc1+2
                lda #$60                        ;Patch exit jump as RTS
                sta DrvExitJump
                lda drv1800Lo-1,x               ;Patch $1800 accesses
                sta DrvPatch1800Lo+1
                lda drv1800Hi-1,x
                sta DrvPatch1800Hi+1
                ldy #10
DrvPatch1800Loop:
                ldx drv1800Ofs,y
DrvPatch1800Lo: lda #$00
                sta DrvMain+1,x
DrvPatch1800Hi: lda #$00
                sta DrvMain+2,x
                dey
                bpl DrvPatch1800Loop
DrvDetectDone:  jsr DrvNoData                   ;DATA low while building the decodetable to signal C64
                ldx #$00
DrvBuildSendTbl:txa                             ;Build high nybble send table
                lsr                             ;May overwrite init drivecode
                lsr
                lsr
                lsr
                tay
                lda drvSendTbl,y
                sta drvSendTblHigh,x
                inx
                bne DrvBuildSendTbl

DrvMain:        jsr DrvGetByte                  ;Get command / filenumber
                bpl DrvLoad
                jmp DrvSave
DrvLoad:        tay
                ldx drvFileTrk,y                ;Check if has entry for file
                bne DrvHasEntry
                stx DrvCacheDir+1               ;If not, reset caching
DrvHasEntry:    jsr DrvCacheDir                 ;No-op if already cached and last file was found
                ldy drvReceiveBuf
                lda drvFileSct,y                ;Now check if file was actually found
                ldx drvFileTrk,y
                bne DrvFound
DrvFileNotFound:ldx #$02                        ;Return code $02 = File not found
DrvEndMark:     stx drvBuf+2                    ;Send endmark, return code in X
                lda #$00
                sta drvBuf
                sta drvBuf+1
                beq DrvSendBlk

DrvFound:
DrvSectorLoop:  jsr DrvReadSector               ;Read the data sector
DrvSendBlk:
Drv2MHzSend:    lda drvBuf
                ldx #$00                        ;Set DATA=high to mark data available
Drv2MHzSerialAcc1:
                stx $1800
                tay
                and #$0f
                tax
                lda #$04                        ;Wait for CLK=low
Drv2MHzSerialAcc2:
                bit $1800
                beq Drv2MHzSerialAcc2
                lda drvSendTbl,x
                nop
                nop
Drv2MHzSerialAcc3:
                sta $1800
                asl
                and #$0f
                cmp ($00,x)
                nop
Drv2MHzSerialAcc4:
                sta $1800
                lda drvSendTblHigh,y
                cmp ($00,x)
                nop
Drv2MHzSerialAcc5:
                sta $1800
                asl
                and #$0f
                cmp ($00,x)
                nop
Drv2MHzSerialAcc6:
                sta $1800
                inc Drv2MHzSend+1
                bne Drv2MHzSend
DrvSendDone:    jsr DrvNoData
                lda drvBuf+1                    ;Follow the T/S chain
                ldx drvBuf
                bne DrvSectorLoop
                tay                             ;If 2 first bytes are both 0,
                beq DrvMain                     ;endmark has been sent and can return to main loop
                bne DrvEndMark

DrvNoMoreBytes: sec
                rts
DrvGetSaveByte:
DrvSaveCountLo: lda #$00
                tay
DrvSaveCountHi: ora #$00
                beq DrvNoMoreBytes
                dec DrvSaveCountLo+1
                tya
                bne DrvGetByte
                dec DrvSaveCountHi+1

DrvGetByte:     cli                             ;Timing not critical; allow interrupts (motor will stop)
                ldy #$08                        ;Bit counter
DrvGetBitLoop:  lda #$00
DrvSerialAcc7:  sta $1800                       ;Set CLK & DATA high for next bit
DrvSerialAcc8:  lda $1800
                bmi DrvQuit                     ;Quit if ATN is low
                and #$05                        ;Wait for CLK or DATA going low
                beq DrvSerialAcc8
                sei                             ;Disable interrupts after 1st bit to make sure "no data" signal will be on time
                lsr                             ;Read the data bit
                lda #$02
                bcc DrvGetZero
                lda #$08
DrvGetZero:     ror drvReceiveBuf               ;Store the data bit
DrvSerialAcc9:  sta $1800                       ;And acknowledge by pulling the other line low
DrvSerialAcc10: lda $1800                       ;Wait for either line going high
                and #$05
                cmp #$05
                beq DrvSerialAcc10
                dey
                bne DrvGetBitLoop
DrvNoData:      lda #$02                        ;DATA low - no sector data to be transmitted yet
DrvSerialAcc11: sta $1800                       ;or C64 cannot yet transmit next byte
                lda drvReceiveBuf
                rts

DrvQuit:        pla
                pla
DrvExitJump:    lda #$1a                        ;Restore data direction when exiting
                sta $1802
                jmp InitializeDrive             ;1541 = exit through Initialize, others = exit through RTS

DrvSave:        and #$7f                        ;Extract filenumber
                pha
                jsr DrvGetByte                  ;Get amount of bytes to expect
                sta DrvSaveCountLo+1
                jsr DrvGetByte
                sta DrvSaveCountHi+1
                pla
                tay
                ldx drvFileTrk,y
                bne DrvSaveFound                ;If file not found, just receive the bytes
                beq DrvSaveFinish
DrvSaveFound:   lda drvFileSct,y
DrvSaveSectorLoop:
                jsr DrvReadSector               ;First read the sector for T/S chain
                ldx #$02
DrvSaveByteLoop:jsr DrvGetSaveByte              ;Then get bytes from C64 and write
                bcs DrvSaveSector               ;If last byte, save the last sector
                sta drvBuf,x
                inx
                bne DrvSaveByteLoop
DrvSaveSector:  lda #$90
                jsr DrvDoJob
                lda drvBuf+1                    ;Follow the T/S chain
                ldx drvBuf
                bne DrvSaveSectorLoop
DrvSaveFinish:  jsr DrvGetSaveByte              ;Make sure all bytes are received
                bcc DrvSaveFinish
DrvFlush:       lda #$a2                        ;Flush buffers (1581 and CMD drives)
DrvFlushJsr:    jsr DrvDoJob
                jmp DrvMain

DrvReadSector:
DrvReadTrk:     stx $1000
DrvReadSct:     sta $1000
                lda #$80
DrvDoJob:       sta DrvRetry+1
                jsr DrvLed
DrvRetry:       lda #$80
                ldx #$01
DrvExecJsr:     jsr Drv1541Exec                 ;Exec buffer 1 job
                cmp #$02                        ;Error?
                bcs DrvRetry                    ;Retry infinitely until success
DrvSuccess:     sei                             ;Make sure interrupts now disabled
DrvLed:         lda #$08
DrvLedAcc0:     eor $1c00
DrvLedAcc1:     sta $1c00
                rts

Drv1541Exec:    sta $01                         ;Set command for execution
                cli                             ;Allow interrupts to execute command
Drv1541ExecWait:
                lda $01                         ;Wait until command finishes
                bmi Drv1541ExecWait
                pha
                ldx #$01
DrvCheckID:     lda id,x                        ;Check for disk ID change
                cmp iddrv0,x                    ;(1541 only)
                beq DrvIDOK
                sta iddrv0,x
                lda #$00                        ;If changed, force recache of dir
                sta DrvCacheDir+1
DrvIDOK:        dex
                bpl DrvCheckID
                pla
                rts

DrvFdExec:      jsr $ff54                       ;FD2000 fix By Ninja
                lda $03
                rts

DrvCacheDir:    lda #$00                        ;Skip if already cached
                bne DrvDirCached
                tax
DrvClearFiles:  sta drvFileTrk,x                ;Mark all files as nonexistent first
                inx
                bpl DrvClearFiles
DrvDirTrk:      ldx drv1541DirTrk
DrvDirSct:      lda drv1541DirSct               ;Read disk directory
DrvDirLoop:     jsr DrvReadSector               ;Read sector
                ldy #$02
DrvNextFile:    lda drvBuf,y                    ;File type must be PRG
                and #$83
                cmp #$82
                bne DrvSkipFile
                lda drvBuf+5,y                  ;Must be two-letter filename
                cmp #$a0
                bne DrvSkipFile
                lda drvBuf+3,y                  ;Convert filename (assumed to be hexadecimal)
                jsr DrvDecodeLetter             ;into an index number for the cache
                asl
                asl
                asl
                asl
                sta DrvIndexOr+1
                lda drvBuf+4,y
                jsr DrvDecodeLetter
DrvIndexOr:     ora #$00
                tax
                lda drvBuf+1,y
                sta drvFileTrk,x
                lda drvBuf+2,y
                sta drvFileSct,x
DrvSkipFile:    tya
                clc
                adc #$20
                tay
                bcc DrvNextFile
                lda drvBuf+1                    ;Go to next directory block, until no
                ldx drvBuf                      ;more directory blocks
                bne DrvDirLoop
                inc DrvCacheDir+1               ;Cached, do not cache again until diskside change or file not found
DrvDirCached:   rts

DrvDecodeLetter:sec
                sbc #$30
                cmp #$10
                bcc DrvDecodeLetterDone
                sbc #$07
DrvDecodeLetterDone:
                rts

drvSendTbl:     dc.b $0f,$07,$0d,$05
                dc.b $0b,$03,$09,$01
                dc.b $0e,$06,$0c,$04
                dc.b $0a,$02,$08,$00

drv1541DirSct  = drvSendTbl+7                   ;Byte $01
drv1581DirSct  = drvSendTbl+5                   ;Byte $03

drv1541DirTrk:  dc.b 18

drvReceiveBuf:  dc.b 0

drvRuntimeEnd:

drvIdLocLo:     dc.b $a4,$c6,$e9
drvIdLocHi:     dc.b $fe,$e5,$a6
drvIdByte:      dc.b "8","F","H"

drvExecLo:      dc.b <$ff54,<DrvFdExec,<$ff4e
drvExecHi:      dc.b >$ff54,>DrvFdExec,>$ff4e

drvDirSctLo:    dc.b <drv1581DirSct,<$56,<$2ba9
drvDirSctHi:    dc.b >drv1581DirSct,>$56,>$2ba9

drvDirTrkLo:    dc.b <$022b,<$54,<$2ba7
drvDirTrkHi:    dc.b >$022b,>$54,>$2ba7

drvJobTrkLo:    dc.b <$0008,<$000d,<$000d,<$2802
drvJobTrkHi:    dc.b >$0008,>$000d,>$000d,>$2802

drvLedBit:      dc.b $40,$40,$00
drvLedAdrHi:    dc.b $40,$40,$05
drv1800Lo:      dc.b <$4001,<$4001,<$8000
drv1800Hi:      dc.b >$4001,>$4001,>$8000

drv1800Ofs:     dc.b Drv2MHzSerialAcc1-DrvMain
                dc.b Drv2MHzSerialAcc2-DrvMain
                dc.b Drv2MHzSerialAcc3-DrvMain
                dc.b Drv2MHzSerialAcc4-DrvMain
                dc.b Drv2MHzSerialAcc5-DrvMain
                dc.b Drv2MHzSerialAcc6-DrvMain
                dc.b DrvSerialAcc7-DrvMain
                dc.b DrvSerialAcc8-DrvMain
                dc.b DrvSerialAcc9-DrvMain
                dc.b DrvSerialAcc10-DrvMain
                dc.b DrvSerialAcc11-DrvMain

DrvCodeEnd:
                rend

ilDriveCodeEnd:

        ; Drive detection + drivecode upload commands

ilMWString:     dc.b MW_LENGTH,>drvStart, <drvStart,"W-M"
ilMEString:     dc.b >DrvDetect,<DrvDetect, "E-M"
ilNumPackets:   dc.b (ilDriveCodeEnd-ilDriveCode+MW_LENGTH-1)/MW_LENGTH
ilUICmd:        dc.b "UI"
ilIDStrings:    dc.b "TRIV"
                dc.b "EDI "
                dc.b "I2DS"
                dc.b "CEIU"
ilIDBuffer:     ds.b 7,0

                if DrvMain != $0500
                    err
                endif
                if DrvSerialAcc11 - DrvMain > $ff
                    err
                endif
                if drvRuntimeEnd > drvSendTblHigh
                    err
                endif
                if DrvCodeEnd > $0800
                    err
                endif

