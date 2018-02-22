USE [Change this to name of the MDT Database]
GO
/****** Object:  StoredProcedure [dbo].[InventoryComputer]    Script Date: 2/22/2018 1:13:36 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[InventoryComputer] 
	@UUID as nvarchar(50),
    @AssetTag as nvarchar(255),
    @SerialNumber as nvarchar(255),
    @MacAddress as nvarchar(50),    
    @OSDComputerName as nvarchar(255), 
	@MakeAlias nvarchar(255),
	@ModelAlias nvarchar(255),
	@MemoryInGB as nvarchar(255),
    @NumberOfProcessors as nvarchar(255),
    @CPUName as nvarchar(255),
    @DiskDriveCaptation as nvarchar(255),
	@DiskDriveSize as nvarchar(255),
	@NetAdapterName as nvarchar(255),
	@GPUAdapterName as nvarchar(255)
	
AS
BEGIN
   SET NOCOUNT ON; 

   DECLARE @COMPUTERID AS INT
   IF EXISTS (SELECT 1 FROM dbo.ComputerIdentity WHERE (SerialNumber = @SerialNumber AND @SerialNumber <> '') OR (AssetTag = @AssetTag AND @AssetTag <> '') OR (MacAddress = @MacAddress AND @MacAddress <> '') OR (UUID = @UUID AND @UUID <> ''))
   BEGIN
      BEGIN TRAN
	  SET @COMPUTERID = (SELECT ID From dbo.ComputerIdentity Where (SerialNumber = @SerialNumber AND @SerialNumber <> '') OR (AssetTag = @AssetTag AND @AssetTag <> '') OR (MacAddress = @MacAddress AND @MacAddress <> '') OR (UUID = @UUID AND @UUID <> ''))
      UPDATE dbo.ComputerIdentity
      SET SerialNumber = @SerialNumber,
          AssetTag = @AssetTag,
          MacAddress = @MacAddress,
          UUID = @UUID,
          [Description] = @OSDComputerName
      WHERE ID = @COMPUTERID 

      UPDATE dbo.Settings
      SET OSDComputerName = @OSDComputerName,
		InvMakeAlias = @MakeAlias,
		InvModelAlias = @ModelAlias,
		InvMemory = @MemoryInGB,
		InvNumberOfProcessors = @NumberOfProcessors,
		InvCPUName = @CPUName,
		InvDiskDriveCaptation = @DiskDriveCaptation,
		InvDiskDriveSize = @DiskDriveSize,
		InvNetAdapterName = @NetAdapterName,
		InvGPUAdapterName = @GPUAdapterName

      WHERE [Type] = 'C' AND ID = @COMPUTERID 
	  COMMIT TRAN
   END 

   ELSE 

   BEGIN
      BEGIN TRAN
	  INSERT INTO dbo.ComputerIdentity
      (SerialNumber,MacAddress,UUID,[Description])
      VALUES
      (@SerialNumber,@MacAddress,@UUID,@OSDComputerName)

      SET @COMPUTERID = SCOPE_IDENTITY()
      INSERT INTO dbo.Settings
      (ID,[Type],OSDComputerName,InvMakeAlias,InvModelAlias,InvMemory,InvNumberOfProcessors,InvCPUName,InvDiskDriveCaptation,InvDiskDriveSize,InvNetAdapterName,InvGPUAdapterName)
      VALUES
      (@COMPUTERID,'C',@OSDComputerName,@MakeAlias,@ModelAlias,@MemoryInGB,@NumberOfProcessors,@CPUName,@DiskDriveCaptation,@DiskDriveSize,@NetAdapterName,@GPUAdapterName)
	  
	  COMMIT TRAN
   END 

END

SELECT 1 FROM dbo.ComputerIdentity WHERE (SerialNumber = @SerialNumber AND @SerialNumber <> '') OR (MacAddress = @MacAddress AND @MacAddress <> '')
