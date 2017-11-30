USE SUSDB
DECLARE @var1 INT 
                                DECLARE @msg nvarchar(100) 
                                 CREATE TABLE #results (Col1 INT) 
                                INSERT INTO #results(Col1) EXEC spGetObsoleteUpdatesToCleanup 
                                 DECLARE WC Cursor 
                                FOR 
                                SELECT Col1 FROM #results 
                                OPEN WC 
                                FETCH NEXT FROM WC 
                                INTO @var1 
                                WHILE (@@FETCH_STATUS > -1) 
                                BEGIN SET @msg = 'Deleting ' + CONVERT(varchar(10), @var1) 
                                RAISERROR(@msg,0,1) WITH NOWAIT EXEC spDeleteUpdate @localUpdateID=@var1 
                                FETCH NEXT FROM WC INTO @var1 END 
                                CLOSE WC 
                                DEALLOCATE WC 
DROP TABLE #results