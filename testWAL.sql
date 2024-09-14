WHILE (@BalanceAmt < 0)
BEGIN
    -- Calculate interest if applicable
    IF (@InterestAppliedToCode = '1' AND @NextInterestSequence = @CurrentSequence)
    BEGIN
        SET @InterestAmt = @BalanceAmt * @EffIntRate * 90 / 36500
        SET @BalanceAmt += @InterestAmt
        SET @NextInterestSequence += 3
        SET @RepaymentInterest += @InterestAmt
    END
    ELSE
    BEGIN
        SET @InterestAmt = 0
    END

    -- Process repayment
    IF (@InterestAppliedToCode <> '1' OR @Sequence = @CurrentSequence)
    BEGIN
        -- Calculate next payment date
        SET @NextPayment = CASE
            WHEN @IsFirstPayment = 1 THEN @NextPaymentDate
            ELSE DATEADD(MONTH, @RepayPeriodMths, @NextPaymentDate)
        END

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
        ORDER BY AsAtDate DESC

        -- Update balance amount
        SET @BalanceAmt += CASE
            WHEN @ExpiryDate > @NextPaymentDate THEN @RepaymentAmt
            ELSE 0
        END
        
        -- Calculate next repayment amount
        SET @NextRepaymentAmt = CASE
            WHEN @ExpiryDate <= @NextPaymentDate THEN ABS(@BalanceAmt) + @RepaymentInterest
            WHEN @BalanceAmt + @RepaymentAmt < @RepaymentAmt THEN @RepaymentAmt + @RepaymentInterest
            ELSE ABS(@BalanceAmt) + @RepaymentInterest
        END

        -- Insert into repayment schedule
        INSERT INTO DW.CAU_RepaymentsSchedules_TEMP (FacilityId, RepaymentAmount, PrincipalAmount, PaymentDate)
        VALUES (
            @FacilityId, 
            @NextRepaymentAmt, 
            CASE 
                WHEN @BalanceAmt > 0 OR @ExpiryDate <= @NextPaymentDate THEN 0
                ELSE ABS(@BalanceAmt)
            END,
            @NextPaymentDate
        )

        -- Update variables for next iteration
        SET @IsFirstPayment = 0
        SET @BalanceAmt = CASE
            WHEN @ExpiryDate <= @NextPaymentDate THEN 0
            ELSE @BalanceAmt
        END
        SET @Sequence += @RepayPeriodMths
        SET @RepaymentInterest = 0.0
    END

    SET @CurrentSequence += 1
END
