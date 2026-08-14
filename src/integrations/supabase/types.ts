export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.15"
  }
  public: {
    Tables: {
      account_transactions: {
        Row: {
          amount: number
          counter_customer_id: string | null
          created_at: string
          customer_id: string
          description: string
          document_no: string
          due_date: string | null
          id: string
          source: string
          source_id: string | null
          txn_date: string
          txn_type: string
          updated_at: string
          user_id: string
        }
        Insert: {
          amount?: number
          counter_customer_id?: string | null
          created_at?: string
          customer_id: string
          description?: string
          document_no?: string
          due_date?: string | null
          id?: string
          source?: string
          source_id?: string | null
          txn_date?: string
          txn_type?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          amount?: number
          counter_customer_id?: string | null
          created_at?: string
          customer_id?: string
          description?: string
          document_no?: string
          due_date?: string | null
          id?: string
          source?: string
          source_id?: string | null
          txn_date?: string
          txn_type?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "account_transactions_counter_customer_id_fkey"
            columns: ["counter_customer_id"]
            isOneToOne: false
            referencedRelation: "customer_balances"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "account_transactions_counter_customer_id_fkey"
            columns: ["counter_customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "account_transactions_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_balances"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "account_transactions_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      admin_audit_log: {
        Row: {
          action: string
          admin_user_id: string
          created_at: string
          details: Json
          id: string
          target_user_id: string | null
        }
        Insert: {
          action: string
          admin_user_id: string
          created_at?: string
          details?: Json
          id?: string
          target_user_id?: string | null
        }
        Update: {
          action?: string
          admin_user_id?: string
          created_at?: string
          details?: Json
          id?: string
          target_user_id?: string | null
        }
        Relationships: []
      }
      customers: {
        Row: {
          address: string
          city: string
          code: string
          contact_name: string
          created_at: string
          district: string
          email: string
          id: string
          neighborhood: string
          note: string
          opening_balance: number
          partner_group: string
          partner_type: string
          payment_term_days: number
          phone: string
          risk_limit: number
          tax_office: string
          title: string
          updated_at: string
          user_id: string
          vkn_tckn: string
        }
        Insert: {
          address?: string
          city?: string
          code?: string
          contact_name?: string
          created_at?: string
          district?: string
          email?: string
          id?: string
          neighborhood?: string
          note?: string
          opening_balance?: number
          partner_group?: string
          partner_type?: string
          payment_term_days?: number
          phone?: string
          risk_limit?: number
          tax_office?: string
          title: string
          updated_at?: string
          user_id: string
          vkn_tckn: string
        }
        Update: {
          address?: string
          city?: string
          code?: string
          contact_name?: string
          created_at?: string
          district?: string
          email?: string
          id?: string
          neighborhood?: string
          note?: string
          opening_balance?: number
          partner_group?: string
          partner_type?: string
          payment_term_days?: number
          phone?: string
          risk_limit?: number
          tax_office?: string
          title?: string
          updated_at?: string
          user_id?: string
          vkn_tckn?: string
        }
        Relationships: []
      }
      efatura_connection_settings: {
        Row: {
          active_provider: string
          created_at: string
          gib_enabled: boolean
          gib_environment: string
          gib_last_error: string
          gib_last_tested_at: string | null
          gib_password_encrypted: string | null
          gib_status: string
          gib_username: string
          integrator_api_key_encrypted: string | null
          integrator_api_username: string
          integrator_base_url: string
          integrator_enabled: boolean
          integrator_last_error: string
          integrator_last_tested_at: string | null
          integrator_provider: string
          integrator_status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          active_provider?: string
          created_at?: string
          gib_enabled?: boolean
          gib_environment?: string
          gib_last_error?: string
          gib_last_tested_at?: string | null
          gib_password_encrypted?: string | null
          gib_status?: string
          gib_username?: string
          integrator_api_key_encrypted?: string | null
          integrator_api_username?: string
          integrator_base_url?: string
          integrator_enabled?: boolean
          integrator_last_error?: string
          integrator_last_tested_at?: string | null
          integrator_provider?: string
          integrator_status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          active_provider?: string
          created_at?: string
          gib_enabled?: boolean
          gib_environment?: string
          gib_last_error?: string
          gib_last_tested_at?: string | null
          gib_password_encrypted?: string | null
          gib_status?: string
          gib_username?: string
          integrator_api_key_encrypted?: string | null
          integrator_api_username?: string
          integrator_base_url?: string
          integrator_enabled?: boolean
          integrator_last_error?: string
          integrator_last_tested_at?: string | null
          integrator_provider?: string
          integrator_status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      invoices: {
        Row: {
          cancel_date: string | null
          created_at: string
          currency: string
          customer: Json
          ettn: string
          exchange_rate: number
          gib_approval_date: string | null
          grand_total: number
          id: string
          invoice_date: string
          invoice_number: string
          items: Json
          notes: string
          payment_info: string
          status: string
          subtotal: number
          taxable_amount: number
          total_discount: number
          total_tevkifat: number
          total_vat: number
          type: string
          updated_at: string
          user_id: string
        }
        Insert: {
          cancel_date?: string | null
          created_at?: string
          currency?: string
          customer?: Json
          ettn: string
          exchange_rate?: number
          gib_approval_date?: string | null
          grand_total?: number
          id?: string
          invoice_date?: string
          invoice_number: string
          items?: Json
          notes?: string
          payment_info?: string
          status?: string
          subtotal?: number
          taxable_amount?: number
          total_discount?: number
          total_tevkifat?: number
          total_vat?: number
          type?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          cancel_date?: string | null
          created_at?: string
          currency?: string
          customer?: Json
          ettn?: string
          exchange_rate?: number
          gib_approval_date?: string | null
          grand_total?: number
          id?: string
          invoice_date?: string
          invoice_number?: string
          items?: Json
          notes?: string
          payment_info?: string
          status?: string
          subtotal?: number
          taxable_amount?: number
          total_discount?: number
          total_tevkifat?: number
          total_vat?: number
          type?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      legal_documents: {
        Row: {
          content: string
          created_at: string
          created_by: string | null
          doc_type: string
          id: string
          is_published: boolean
          published_at: string
          requires_reacceptance: boolean
          title: string
          updated_at: string
          version: string
        }
        Insert: {
          content: string
          created_at?: string
          created_by?: string | null
          doc_type: string
          id?: string
          is_published?: boolean
          published_at?: string
          requires_reacceptance?: boolean
          title: string
          updated_at?: string
          version: string
        }
        Update: {
          content?: string
          created_at?: string
          created_by?: string | null
          doc_type?: string
          id?: string
          is_published?: boolean
          published_at?: string
          requires_reacceptance?: boolean
          title?: string
          updated_at?: string
          version?: string
        }
        Relationships: []
      }
      pos_sales: {
        Row: {
          created_at: string
          description: string
          document_no: string
          gross_amount: number
          id: string
          net_amount: number
          payment_type: string
          sale_date: string
          updated_at: string
          user_id: string
          vat_amount: number
          vat_rate: number
        }
        Insert: {
          created_at?: string
          description?: string
          document_no?: string
          gross_amount?: number
          id?: string
          net_amount?: number
          payment_type?: string
          sale_date?: string
          updated_at?: string
          user_id: string
          vat_amount?: number
          vat_rate?: number
        }
        Update: {
          created_at?: string
          description?: string
          document_no?: string
          gross_amount?: number
          id?: string
          net_amount?: number
          payment_type?: string
          sale_date?: string
          updated_at?: string
          user_id?: string
          vat_amount?: number
          vat_rate?: number
        }
        Relationships: []
      }
      products: {
        Row: {
          barcode: string
          category: string
          code: string
          created_at: string
          description: string
          discount_rate: number
          id: string
          min_stock: number
          name: string
          purchase_price: number
          track_stock: boolean
          unit: string
          unit_price: number
          updated_at: string
          user_id: string
          vat_rate: number
        }
        Insert: {
          barcode?: string
          category?: string
          code?: string
          created_at?: string
          description?: string
          discount_rate?: number
          id?: string
          min_stock?: number
          name: string
          purchase_price?: number
          track_stock?: boolean
          unit?: string
          unit_price?: number
          updated_at?: string
          user_id: string
          vat_rate?: number
        }
        Update: {
          barcode?: string
          category?: string
          code?: string
          created_at?: string
          description?: string
          discount_rate?: number
          id?: string
          min_stock?: number
          name?: string
          purchase_price?: number
          track_stock?: boolean
          unit?: string
          unit_price?: number
          updated_at?: string
          user_id?: string
          vat_rate?: number
        }
        Relationships: []
      }
      profiles: {
        Row: {
          address: string
          company_title: string
          created_at: string
          email: string
          id: string
          phone: string
          tax_office: string
          updated_at: string
          vkn_tckn: string
        }
        Insert: {
          address?: string
          company_title?: string
          created_at?: string
          email?: string
          id: string
          phone?: string
          tax_office?: string
          updated_at?: string
          vkn_tckn?: string
        }
        Update: {
          address?: string
          company_title?: string
          created_at?: string
          email?: string
          id?: string
          phone?: string
          tax_office?: string
          updated_at?: string
          vkn_tckn?: string
        }
        Relationships: []
      }
      stock_movements: {
        Row: {
          created_at: string
          customer_id: string | null
          description: string
          document_no: string
          id: string
          movement_date: string
          movement_type: string
          product_id: string
          quantity: number
          source: string
          source_id: string | null
          target_warehouse_id: string | null
          unit_price: number
          updated_at: string
          user_id: string
          warehouse_id: string | null
        }
        Insert: {
          created_at?: string
          customer_id?: string | null
          description?: string
          document_no?: string
          id?: string
          movement_date?: string
          movement_type?: string
          product_id: string
          quantity?: number
          source?: string
          source_id?: string | null
          target_warehouse_id?: string | null
          unit_price?: number
          updated_at?: string
          user_id: string
          warehouse_id?: string | null
        }
        Update: {
          created_at?: string
          customer_id?: string | null
          description?: string
          document_no?: string
          id?: string
          movement_date?: string
          movement_type?: string
          product_id?: string
          quantity?: number
          source?: string
          source_id?: string | null
          target_warehouse_id?: string | null
          unit_price?: number
          updated_at?: string
          user_id?: string
          warehouse_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "stock_movements_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_balances"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "stock_movements_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "product_stocks"
            referencedColumns: ["product_id"]
          },
          {
            foreignKeyName: "stock_movements_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_target_warehouse_id_fkey"
            columns: ["target_warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stock_movements_warehouse_id_fkey"
            columns: ["warehouse_id"]
            isOneToOne: false
            referencedRelation: "warehouses"
            referencedColumns: ["id"]
          },
        ]
      }
      subscription_reminders: {
        Row: {
          email: string
          end_date: string
          id: string
          sent_at: string
          threshold_days: number
          user_id: string
        }
        Insert: {
          email: string
          end_date: string
          id?: string
          sent_at?: string
          threshold_days: number
          user_id: string
        }
        Update: {
          email?: string
          end_date?: string
          id?: string
          sent_at?: string
          threshold_days?: number
          user_id?: string
        }
        Relationships: []
      }
      subscriptions: {
        Row: {
          created_at: string
          end_date: string
          id: string
          last_payment_date: string | null
          plan: string
          renewal_price: number | null
          start_date: string
          status: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          end_date?: string
          id?: string
          last_payment_date?: string | null
          plan?: string
          renewal_price?: number | null
          start_date?: string
          status?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          end_date?: string
          id?: string
          last_payment_date?: string | null
          plan?: string
          renewal_price?: number | null
          start_date?: string
          status?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      user_consents: {
        Row: {
          accepted: boolean
          accepted_at: string
          consent_type: string
          created_at: string
          document_version: string
          id: string
          user_agent: string
          user_id: string
        }
        Insert: {
          accepted?: boolean
          accepted_at?: string
          consent_type: string
          created_at?: string
          document_version?: string
          id?: string
          user_agent?: string
          user_id: string
        }
        Update: {
          accepted?: boolean
          accepted_at?: string
          consent_type?: string
          created_at?: string
          document_version?: string
          id?: string
          user_agent?: string
          user_id?: string
        }
        Relationships: []
      }
      user_roles: {
        Row: {
          created_at: string
          id: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          role?: Database["public"]["Enums"]["app_role"]
          user_id?: string
        }
        Relationships: []
      }
      warehouses: {
        Row: {
          address: string
          created_at: string
          id: string
          is_default: boolean
          name: string
          updated_at: string
          user_id: string
        }
        Insert: {
          address?: string
          created_at?: string
          id?: string
          is_default?: boolean
          name: string
          updated_at?: string
          user_id: string
        }
        Update: {
          address?: string
          created_at?: string
          id?: string
          is_default?: boolean
          name?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
    }
    Views: {
      customer_balances: {
        Row: {
          balance: number | null
          customer_id: string | null
          total_credit: number | null
          total_debit: number | null
          user_id: string | null
        }
        Relationships: []
      }
      product_stocks: {
        Row: {
          product_id: string | null
          quantity: number | null
          user_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      has_active_subscription: { Args: { _user_id: string }; Returns: boolean }
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
    }
    Enums: {
      app_role: "admin" | "user"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      app_role: ["admin", "user"],
    },
  },
} as const
