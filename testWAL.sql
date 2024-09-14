-- Create a temporary table to store results
CREATE TABLE #TempRepaymentSchedule (
    FacilityId INT,
    RepaymentAmount DECIMAL(18,2),
    PrincipalAmount DECIMAL(18,2),
    PaymentDate DATE
);

-- Optimize the WHILE loop
WHILE (@BalanceAmt < 0)
BEGIN
    -- Calculate interest if applicable
    IF (@InterestAppliedToCode = '1' AND @CurrentSequence = @NextInterestSequence)
    BEGIN
        SET @InterestAmt = @BalanceAmt * @EffIntRate * 90 / 36500;
        SET @BalanceAmt = @BalanceAmt + @InterestAmt;
        SET @NextInterestSequence = @NextInterestSequence + 3;
        SET @RepaymentInterest = @RepaymentInterest + @InterestAmt;
    END
    ELSE
    BEGIN
        SET @InterestAmt = 0;
    END

    -- Process repayment
    IF (@InterestAppliedToCode <> '1' OR @Sequence = @CurrentSequence)
    BEGIN
        SET @NextPayment = CASE
            WHEN @IsFirstPayment = 1 THEN @NextPaymentDate
            ELSE DATEADD(MONTH, @RepayPeriodMths, @NextPaymentDate)
        END;

        -- Get the next working day payment date
        SELECT TOP 1 @NextPaymentDate = CASE
            WHEN @ExpiryDate <= AsAtDate THEN @ExpiryDate
            ELSE AsAtDate
        END
        FROM [dbo].[syn_Model_tbl_Dim_Calendar]
        WHERE RegionCode = 'UK' 
          AND IsWorkingDay = 1 
          AND [Month] = MONTH(@NextPayment)
          AND [Year] = YEAR(@NextPayment)
          AND AsAtDate <= @ExpiryDate
        ORDER BY AsAtDate DESC;

        SET @BalanceAmt = CASE
            WHEN @ExpiryDate > @NextPaymentDate THEN @BalanceAmt + @RepaymentAmt
            ELSE @BalanceAmt
        END;
        
        SET @NextRepaymentAmt = CASE
            WHEN @ExpiryDate <= @NextPaymentDate THEN ABS(@BalanceAmt) + @RepaymentInterest
            WHEN @BalanceAmt + @RepaymentAmt < @RepaymentAmt THEN @RepaymentAmt + @RepaymentInterest
            ELSE ABS(@BalanceAmt) + @RepaymentInterest
        END;

        -- Insert into temporary table instead of permanent table
        INSERT INTO #TempRepaymentSchedule (FacilityId, RepaymentAmount, PrincipalAmount, PaymentDate)
        VALUES (
            @FacilityId, 
            @NextRepaymentAmt, 
            CASE 
                WHEN @BalanceAmt > 0 OR @ExpiryDate <= @NextPaymentDate THEN 0
                ELSE ABS(@BalanceAmt)
            END,
            @NextPaymentDate
        );

        SET @IsFirstPayment = 0;
        SET @BalanceAmt = CASE
            WHEN @ExpiryDate <= @NextPaymentDate THEN 0
            ELSE @BalanceAmt
        END;
        SET @Sequence = @Sequence + @RepayPeriodMths;
        SET @RepaymentInterest = 0.0;
    END

    SET @CurrentSequence = @CurrentSequence + 1;
END

-- Bulk insert from temporary table to permanent table
INSERT INTO DW.CAU_RepaymentsSchedules_TEMP (FacilityId, RepaymentAmount, PrincipalAmount, PaymentDate)
SELECT FacilityId, RepaymentAmount, PrincipalAmount, PaymentDate
FROM #TempRepaymentSchedule;

-- Clean up
DROP TABLE #TempRepaymentSchedule;
