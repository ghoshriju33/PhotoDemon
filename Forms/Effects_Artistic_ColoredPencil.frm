VERSION 5.00
Begin VB.Form FormPencil 
   Appearance      =   0  'Flat
   BackColor       =   &H80000005&
   Caption         =   " Colored pencil"
   ClientHeight    =   6540
   ClientLeft      =   120
   ClientTop       =   465
   ClientWidth     =   12030
   DrawStyle       =   5  'Transparent
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   8.25
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   HasDC           =   0   'False
   LinkTopic       =   "Form1"
   MaxButton       =   0   'False
   MinButton       =   0   'False
   ScaleHeight     =   436
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   802
   ShowInTaskbar   =   0   'False
   Begin PhotoDemon.pdSlider sldAngle 
      Height          =   705
      Left            =   6000
      TabIndex        =   6
      Top             =   840
      Width           =   5895
      _ExtentX        =   10398
      _ExtentY        =   1244
      Caption         =   "angle"
      Max             =   360
      Value           =   45
      DefaultValue    =   45
   End
   Begin PhotoDemon.pdRandomizeUI rndSeed 
      Height          =   855
      Left            =   6000
      TabIndex        =   5
      Top             =   4200
      Width           =   5895
      _ExtentX        =   10398
      _ExtentY        =   1508
      Caption         =   "random seed:"
   End
   Begin PhotoDemon.pdCommandBar cmdBar 
      Height          =   750
      Left            =   0
      TabIndex        =   0
      Top             =   5790
      Width           =   12030
      _ExtentX        =   21220
      _ExtentY        =   1323
   End
   Begin PhotoDemon.pdFxPreviewCtl pdFxPreview 
      Height          =   5625
      Left            =   120
      TabIndex        =   1
      Top             =   120
      Width           =   5625
      _ExtentX        =   9922
      _ExtentY        =   9922
   End
   Begin PhotoDemon.pdSlider sldRadius 
      Height          =   705
      Left            =   6000
      TabIndex        =   2
      Top             =   1680
      Width           =   5895
      _ExtentX        =   10398
      _ExtentY        =   1270
      Caption         =   "tip radius"
      Min             =   2
      Max             =   100
      Value           =   5
      DefaultValue    =   5
   End
   Begin PhotoDemon.pdSlider sldDensity 
      Height          =   705
      Left            =   6000
      TabIndex        =   3
      Top             =   2520
      Width           =   5895
      _ExtentX        =   10398
      _ExtentY        =   1270
      Caption         =   "density"
      Min             =   1
      Max             =   100
      Value           =   100
      NotchPosition   =   2
      NotchValueCustom=   100
   End
   Begin PhotoDemon.pdSlider sldEdgeThreshold 
      Height          =   705
      Left            =   6000
      TabIndex        =   4
      Top             =   3360
      Width           =   5895
      _ExtentX        =   10398
      _ExtentY        =   1270
      Caption         =   "threshold"
      Min             =   1
      Max             =   100
      Value           =   25
      NotchPosition   =   2
      NotchValueCustom=   25
   End
End
Attribute VB_Name = "FormPencil"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = False
'***************************************************************************
'Pencil Sketch Image Effect
'Copyright 2001-2020 by Tanner Helland
'Created: sometime 2001
'Last updated: 28/September/20
'Last update: attempted overhaul
'
'PhotoDemon has provided a pencil sketch tool for a long time, but despite going through many incarnations, it always
' used low-quality, "quick and dirty" approximations.
'
'In July '14, this changed, and the entire tool was rethought from the ground up.  A dialog is now provided, with options
' for pencil style, tip thickness, and stroke pressure.  This yields much more flexible results, and the use of PD's
' central compositor for overlaying various image copies keeps things nice and fast.
'
'Unless otherwise noted, all source code in this file is shared under a simplified BSD license.
' Full license details are available in the LICENSE.md file, or at https://photodemon.org/license/
'
'***************************************************************************

Option Explicit

'To improve performance, we cache a local temporary DIB when generating previews
Private m_blurDIB As pdDIB

'Suppress duplicate previews
Private m_LastPreviewParams As String

'Apply a "colored pencil" effect to an image
'Inputs:
' 1) radius of the pencil tip (min 1, no real max - but processing speed obviously drops as the radius increases)
' 2) color intensity, which controls the vibrance applied to the resulting color
' 3) pencil style, a nebulous setting that controls blend mode and post-processing, among other items.  Current values include:
'    0 - normal
'    1 - luminous
'    2 - pastel
'    3 - graphite
Public Sub fxColoredPencil(ByVal effectParams As String, Optional ByVal toPreview As Boolean = False, Optional ByRef dstPic As pdFxPreviewCtl)
    
    If (Not toPreview) Then Message "Sketching image with pencils..."
    
    'Parse parameters out of the incoming param string
    Dim cParams As pdSerialize
    Set cParams = New pdSerialize
    cParams.SetParamString effectParams
    
    Dim penRadius As Single, penDensity As Single, penAngle As Double
    Dim edgeThreshold As Single, rndSeedString As String
    
    With cParams
        penRadius = .GetSingle("radius", 5!, True)
        penDensity = .GetSingle("density", 100, True)
        penAngle = .GetDouble("angle", 45#, True)
        edgeThreshold = .GetSingle("edge-threshold", 10!, True)
        rndSeedString = .GetString("seed", vbNullString, True)
    End With
    
    'Angle needs to be in radians
    penAngle = PDMath.DegreesToRadians(penAngle)
    
    'Edge threshold needs to be scaled from [0, 100] to [0, 20]
    edgeThreshold = edgeThreshold * 0.2
    
    'Initialize a working DIB
    Dim dstSA As SafeArray2D
    EffectPrep.PrepImageData dstSA, toPreview, dstPic
    
    Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
    initX = curDIBValues.Left
    initY = curDIBValues.Top
    finalX = curDIBValues.Right
    finalY = curDIBValues.Bottom
    
    'If this is a preview, we need to adjust the kernel radius to match the size of the preview box
    Dim progBarCheck As Long, prevModifier As Single
    prevModifier = curDIBValues.previewModifier
    
    If toPreview Then
        penRadius = penRadius * prevModifier
        'penDensity = penDensity * curDIBValues.previewModifier
    End If
    
    If (penRadius < 1.6) Then penRadius = 1.6
    
    'Density controls the limiting radius that we pass to the poisson disc generator.
    ' As such, HIGHER density equals a LOWER limiting radius (with a minimum value of
    ' 1, where we simply use the input radius as-is).
    penDensity = penDensity * 0.01!
    penDensity = 1! + (1! - penDensity) * 2!
    
    'Use the density value to sample a bunch of random points from the image
    Dim cPoints As pdPoissonDisc
    Set cPoints = New pdPoissonDisc
    
    Dim listOfPoints() As PointFloat, numOfPoints As Long
    Dim ptGrid() As Long, gridWidth As Long, gridHeight As Long
    
    'The number of points in our sampling disc determines progress bar max
    If (Not toPreview) Then
        ProgressBars.SetProgBarMax 100
        progBarCheck = ProgressBars.FindBestProgBarValue()
    End If
    
    'Retrieve image gradient and magnitude
    Dim imgGrad() As Byte, imgMag() As Byte
    ReDim imgGrad(0 To workingDIB.GetDIBWidth - 1, 0 To workingDIB.GetDIBHeight - 1) As Byte
    ReDim imgMag(0 To workingDIB.GetDIBWidth - 1, 0 To workingDIB.GetDIBHeight - 1) As Byte
    Filters_Scientific.GetImageGradAndMag workingDIB, imgGrad, imgMag
    
    'Prep a new destination DIB
    Dim newDIB As pdDIB
    Set newDIB = New pdDIB
    newDIB.CreateFromExistingDIB workingDIB
    newDIB.ResetDIB 255
    
    'We want to randomize angles to make the strokes look more natural
    Dim cRandomize As pdRandomize
    Set cRandomize = New pdRandomize
    cRandomize.SetSeed_String rndSeedString
    
    'This function requires a lot of random values to look interesting; we pre-calculate
    ' a table of random values to improve performance.
    Const NUM_RND_VALUES As Long = 976  'Prime number - 1
    Dim listOfGaussRnd(0 To NUM_RND_VALUES) As Single, rndIndex As Long
    rndIndex = 0
    For rndIndex = 0 To NUM_RND_VALUES
        listOfGaussRnd(rndIndex) = cRandomize.GetGaussianFloat_WH()
    Next rndIndex
    
    'pd2D handles the actual line drawing
    Dim cSurface As pd2DSurface
    Drawing2D.QuickCreateSurfaceFromDIB cSurface, newDIB, False
    
    'We actually use a few different pens of slightly varying sizes;
    ' this makes for a more interesting effect than a bunch of perfectly uniform strokes.
    Const PEN_SIZE_VARIATION As Single = 0.5!
    Const NUM_PEN_OBJECTS As Long = 7
    Dim cPens(0 To NUM_PEN_OBJECTS) As pd2DPen, curPen As pd2DPen, curPenIndex As Long
    
    'Create all pens
    Dim curRadius As Single
    For curPenIndex = 0 To NUM_PEN_OBJECTS
        
        Set cPens(curPenIndex) = New pd2DPen
        With cPens(curPenIndex)
            
            'Set matching line ends and joins
            .SetPenLineCap P2_LC_Round
            .SetPenLineJoin P2_LJ_Round
            
        End With
        
    Next curPenIndex
    curPenIndex = 0
        
    'X/Y steps will be randomized as we go
    Dim curX As Double, curY As Double
    Dim stepX As Double, stepY As Double
    Dim pt1 As PointFloat, pt2 As PointFloat
    
    Const SQR2 As Double = 1.41421356
    
    'We need access to the original image for color-matching
    Dim srcPixels() As RGBQuad, srcSA2D As SafeArray2D, origColor As RGBQuad
    workingDIB.WrapRGBQuadArrayAroundDIB srcPixels, srcSA2D
    
    Dim xBound As Single, yBound As Single
    xBound = finalX + 0.49
    yBound = finalY + 0.49
    
    Dim i As Long, j As Long
    
    'Strokes are all rendered as 3-point curves; this looks a little more interesting
    ' than perfectly straight lines
    Dim drawPoints(0 To 2) As PointFloat
    
    'We randomly extend each stroke beyond its natural terminus, for a more interesting look.
    ' (But the extension amount must be proportionally reduced during previews.)
    Const LINE_EXTEND_PX As Single = 4!
    
    Dim maxExtend As Single, curExtend As Single, lineStep As Single
    maxExtend = LINE_EXTEND_PX
    If toPreview Then maxExtend = maxExtend * curDIBValues.previewModifier
    
    Dim limitRadius As Single
    Const ANGLE_VARIATION As Single = 0.1!
    
    Const minSizeModifier As Single = 1!
    Const maxSizeModifier As Single = 10!
    
    Const NUM_WAVELETS As Long = 3
    
    Dim maxWavelets As Long
    maxWavelets = NUM_WAVELETS - 1
    
    'Iterate through each point in our list, and attempt to draw a nice pen stroke using that point
    For j = 0 To maxWavelets
    
        'Each wavelet uses a predefined multiplier, scaling from 1000% to 100%
        Dim waveRadius As Single
        waveRadius = minSizeModifier + ((maxWavelets - j) / maxWavelets) * (maxSizeModifier - minSizeModifier)
        
        'Recreate all pens
        For curPenIndex = 0 To NUM_PEN_OBJECTS
            
            'Assign a variable radius
            curRadius = (penRadius + PEN_SIZE_VARIATION * listOfGaussRnd(curPenIndex)) * waveRadius
            If (curRadius < 1.6!) Then curRadius = 1.6!
            cPens(curPenIndex).SetPenWidth curRadius
            
            'Assign variable opacity depending on the current wavelet size
            Const MIN_OPACITY As Single = 50!
            Const MAX_OPACITY As Single = 90!
            cPens(curPenIndex).SetPenOpacity MIN_OPACITY + (j / maxWavelets) * (MAX_OPACITY - MIN_OPACITY)
            Debug.Print cPens(curPenIndex).GetPenOpacity
            
        Next curPenIndex
        curPenIndex = 0
        
        'Re-create list of points
        limitRadius = penRadius * Sqr(2#) * penDensity * (waveRadius * 1.5!)
        cPoints.GetDisc listOfPoints, numOfPoints, ptGrid, gridWidth, gridHeight, limitRadius, workingDIB.GetDIBWidth, workingDIB.GetDIBHeight
            
        For i = 0 To numOfPoints - 1
        
            curX = listOfPoints(i).x
            curY = listOfPoints(i).y
            drawPoints(1).x = curX
            drawPoints(1).y = curY
            origColor = srcPixels(curX, curY)
            
            'Ensure we won't run out of values in our random number table
            Const NUM_OF_RNDS_IN_LOOP As Long = 6
            If (rndIndex + NUM_OF_RNDS_IN_LOOP > NUM_RND_VALUES) Then rndIndex = (NUM_RND_VALUES + 1 - rndIndex)
            
            'Starting at the current point, move in direction (lineAngle) until we reach a strong
            ' gradient boundary.
            lineStep = SQR2 * waveRadius * (1! + Abs(listOfGaussRnd(rndIndex)) * 2! * prevModifier)
            rndIndex = rndIndex + 1
            stepX = lineStep * Cos(penAngle + (ANGLE_VARIATION * listOfGaussRnd(rndIndex)))
            rndIndex = rndIndex + 1
            stepY = lineStep * Sin(penAngle)
            
            Do
                curX = curX + stepX
                curY = curY + stepY
                If (curX < 0) Or (curX > xBound) Then Exit Do
                If (curY < 0) Or (curY > yBound) Then Exit Do
            Loop While (imgMag(Int(curX + 0.5), Int(curY + 0.5)) < edgeThreshold)
            
            'curX and curY now point to a pixel that lies on a strong visual boundary.
            drawPoints(0).x = curX
            drawPoints(0).y = curY
            
            'Extend the end of the line by some random amount, to make it look more natural
            'curExtend = maxExtend * Abs(listOfGaussRnd(rndIndex)) '* waveRadius
            'rndIndex = rndIndex + 1
            'drawPoints(0).x = drawPoints(0).x + curExtend * stepX
            'drawPoints(0).y = drawPoints(0).y - curExtend * stepY
            
            'Next, repeat the above steps, but in the opposite direction from the
            ' original pixel; this will extend the line in the opposite direction.
            curX = listOfPoints(i).x
            curY = listOfPoints(i).y
            lineStep = SQR2 * waveRadius * (1! + Abs(listOfGaussRnd(rndIndex)) * 2! * prevModifier)
            rndIndex = rndIndex + 1
            stepX = -1 * lineStep * Cos(penAngle)
            stepY = -1 * lineStep * Sin(penAngle + (ANGLE_VARIATION * listOfGaussRnd(rndIndex)))
            rndIndex = rndIndex + 1
            
            Do
                curX = curX - stepX
                curY = curY - stepY
                If (curX < 0) Or (curX > xBound) Then Exit Do
                If (curY < 0) Or (curY > yBound) Then Exit Do
            Loop While (imgMag(Int(curX + 0.5), Int(curY + 0.5)) < edgeThreshold)
            
            drawPoints(2).x = curX
            drawPoints(2).y = curY
            
            'Again, extend the end of the line by some random amount, to make it look more natural
            'curExtend = maxExtend * listOfGaussRnd(rndIndex) '* waveRadius
            'rndIndex = rndIndex + 1
            'drawPoints(2).x = drawPoints(2).x + curExtend * stepX
            'drawPoints(2).y = drawPoints(2).y - curExtend * stepY
            
            'GDI+ will fail if points are too close together.  Ensure a minimum viable distance?
            
            'Draw a line with the color of the source pixel
            Set curPen = cPens(curPenIndex)
            curPen.SetPenColor RGB(origColor.Red, origColor.Green, origColor.Blue)
            If Not PD2D.DrawLinesF_FromPtF(cSurface, curPen, 3, VarPtr(drawPoints(0)), True) Then
                Dim q As Long
                For q = 0 To 2
                    Debug.Print drawPoints(q).x, drawPoints(q).y
                Next q
            End If
            
            'Rotate between pens as we go
            curPenIndex = curPenIndex + 1
            If (curPenIndex > NUM_PEN_OBJECTS) Then curPenIndex = 0
            
            If (Not toPreview) Then
                If (i And progBarCheck) = 0 Then
                    If Interface.UserPressedESC() Then Exit For
                    ProgressBars.SetProgBarVal i + (j * numOfPoints)
                End If
            End If
                
        Next i
        
    'Next wavelet
    Next j
    
    workingDIB.UnwrapRGBQuadArrayFromDIB srcPixels
    workingDIB.CreateFromExistingDIB newDIB
    
    Set cSurface = Nothing
    
    'Pass control to finalizeImageData, which will handle the rest of the rendering
    EffectPrep.FinalizeImageData toPreview, dstPic
    
End Sub

Private Sub cmdBar_OKClick()
    Process "Colored pencil", , GetLocalParamString(), UNDO_Layer
End Sub

Private Sub cmdBar_RequestPreviewUpdate()
    UpdatePreview
End Sub

Private Sub Form_Load()
    
    'Disable previews until the dialog is fully loaded
    cmdBar.SetPreviewStatus False
    
    'These are dummy entries because I don't want to lose these translations yet, as I may add them
    ' back as options in the future.
    Dim dummyString As String
    dummyString = g_Language.TranslateMessage("pressure")
    dummyString = g_Language.TranslateMessage("Luminous")
    dummyString = g_Language.TranslateMessage("Pastel")
    dummyString = g_Language.TranslateMessage("Graphite")
    
    'Apply translations and visual themes
    ApplyThemeAndTranslations Me, True, True
    cmdBar.SetPreviewStatus True
    UpdatePreview
    
End Sub

Private Sub Form_Unload(Cancel As Integer)
    ReleaseFormTheming Me
End Sub

'Render a new effect preview
Private Sub UpdatePreview(Optional ByVal forceUpdate As Boolean = False)
    If cmdBar.PreviewsAllowed Then
        If Strings.StringsNotEqual(m_LastPreviewParams, GetLocalParamString(), True) Or forceUpdate Then
            Me.fxColoredPencil GetLocalParamString(), True, pdFxPreview
            m_LastPreviewParams = GetLocalParamString()
        End If
    End If
End Sub

'If the user changes the position and/or zoom of the preview viewport, the entire preview must be redrawn.
Private Sub pdFxPreview_ViewportChanged()
    UpdatePreview True
End Sub

Private Function GetLocalParamString() As String
    
    Dim cParams As pdSerialize
    Set cParams = New pdSerialize
    
    With cParams
        .AddParam "angle", sldAngle.Value
        .AddParam "radius", sldRadius.Value
        .AddParam "density", sldDensity.Value
        .AddParam "edge-threshold", sldEdgeThreshold.Value
        .AddParam "seed", rndSeed.Value
    End With
    
    GetLocalParamString = cParams.GetParamString()
    
End Function

Private Sub rndSeed_Change()
    UpdatePreview
End Sub

Private Sub sldAngle_Change()
    UpdatePreview
End Sub

Private Sub sldDensity_Change()
    UpdatePreview
End Sub

Private Sub sldEdgeThreshold_Change()
    UpdatePreview
End Sub

Private Sub sldRadius_Change()
    UpdatePreview
End Sub
